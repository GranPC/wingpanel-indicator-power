/*
 * Copyright (c) 2011-2015 elementary LLC. (https://elementary.io)
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public
 * License as published by the Free Software Foundation; either
 * version 2 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public
 * License along with this program; if not, write to the
 * Free Software Foundation, Inc., 51 Franklin Street - Fifth Floor,
 * Boston, MA 02110-1301, USA.
 */

public class Power.Services.ProcessMonitor.Monitor : Object {
    public double cpu_load { get; private set; }
    private double[] cpu_loads;

    uint64 cpu_last_used = 0;
    uint64 cpu_last_total = 0;
    uint64[] cpu_last_useds = new uint64[32];
    uint64[] cpu_last_totals = new uint64[32];

    private Gee.HashMap<int, Process> process_list;
    private Gee.HashSet<int> kernel_process_blacklist;

    public signal void process_added (int pid, Process process);
    public signal void process_removed (int pid);
    public signal void updated ();

    private static Monitor? instance = null;

    /**
     * Construct a new ProcessMonitor
     */
    private Monitor () {
        debug ("Initialising process monitor.");

        process_list = new Gee.HashMap<int, Process> ();
        kernel_process_blacklist = new Gee.HashSet<int> ();
        update_processes.begin ();
        cpu_load = 0;
    }

    public void update () {
        update_processes.begin ();

        /* Do it one more time for better accuracy */
        Timeout.add (100, () => {
            update_processes.begin ();

            return false;
        });
    }

    public static Monitor get_default () {
        if (instance == null) {
            instance = new Monitor ();
        }

        return instance;
    }

    /**
     * Gets a process by its pid, making sure that it's updated.
     */
    public Process? get_process (int pid) {
        /* if the process is in the kernel blacklist, we don't want to deal with it. */
        if (kernel_process_blacklist.contains (pid)) {
            return null;
        }

        /* else, return our cached version. */
        if (process_list.has_key (pid)) {
            return process_list[pid];
        }

        /*
         * else return the result of add_process
         * make sure to lazily call the callback since this is a greedy add
         * this way we don't interrupt whatever this method is being called for
         */

        /* with a handle_add_process */
        return add_process (pid, true);
    }

    /**
     * Returns all direct sub processes of this process
     */
    public Gee.Set<int> get_sub_processes (int pid) {
        var sub_processes = new Gee.HashSet<int> ();

        /* go through and add all of the processes with PPID set to this one */
        foreach (var process in process_list.values) {
            if (process.ppid == pid) {
                sub_processes.add (process.pid);
            }
        }

        return sub_processes;
    }

    /**
     * Gets a read only map of the processes currently cached
     */
    public Gee.Map<int, Process> get_process_list () {
        return process_list.read_only_view;
    }

    /**
     * Gets all new process and adds them
     */
    private async void update_processes () {
        /* CPU */
        GTop.Cpu cpu_data;
        GTop.get_cpu (out cpu_data);
        var used = cpu_data.user + cpu_data.nice + cpu_data.sys;
        cpu_load = ((double) (used - cpu_last_used)) / (cpu_data.total - cpu_last_total);
        cpu_loads = new double[cpu_data.xcpu_user.length];
        var useds = new uint64[cpu_data.xcpu_user.length];

        for (int i = 0; i < cpu_data.xcpu_user.length; i++) {
            useds[i] = cpu_data.xcpu_user[i] + cpu_data.xcpu_nice[i] + cpu_data.xcpu_sys[i];
        }

        for (int i = 0; i < cpu_data.xcpu_user.length; i++) {
            cpu_loads[i] = ((double) (useds[i] - cpu_last_useds[i])) /
                           (cpu_data.xcpu_total[i] - cpu_last_totals[i]);
        }

        var remove_me = new Gee.HashSet<int> ();

        /* go through each process and update it, removing the old ones */
        foreach (var process in process_list.values) {
            if (!process.update (cpu_data.total, cpu_last_total)) {
                /* process doesn't exist any more, flag it for removal! */
                remove_me.add (process.pid);
            }
        }

        /* remove everything from flags */
        foreach (var pid in remove_me) {
            remove_process (pid);
        }

        var uid = Posix.getuid ();
        GTop.ProcList proclist;
        var pids = GTop.get_proclist (out proclist, GTop.GLIBTOP_KERN_PROC_UID, uid);

        for (int i = 0; i < proclist.number; i++) {
            int pid = pids[i];

            if (!process_list.has_key (pid) && !kernel_process_blacklist.contains (pid)) {
                add_process (pid);
            }
        }

        cpu_last_used = used;
        cpu_last_total = cpu_data.total;
        cpu_last_useds = useds;
        cpu_last_totals = cpu_data.xcpu_total;

        /* call the updated signal so that subscribers can update */
        updated ();
    }

    /**
     * Parses a pid and adds a Process to our process_list or to the kernel_blacklist
     *
     * returns the created process
     */
    private Process? add_process (int pid, bool lazy_signal = false) {
        /* create the process */
        var process = new Process (pid);

        if (process.exists) {
            if (process.pgrp != 0) {
                /* regular process, add it to our cache */
                process_list.set (pid, process);

                /* call the signal, lazily if needed */
                if (lazy_signal) {
                    Idle.add (() => { process_added (pid, process); return false; });
                } else {
                    process_added (pid, process);
                }

                return process;
            } else {
                /* add it to our kernel processes blacklist */
                kernel_process_blacklist.add (pid);
            }
        }

        return null;
    }

    /**
     * Remove the process from all lists and broadcast the process_removed signal if removed.
     */
    private void remove_process (int pid) {
        if (process_list.has_key (pid)) {
            process_list.unset (pid);
            process_removed (pid);
        } else if (kernel_process_blacklist.contains (pid)) {
            kernel_process_blacklist.remove (pid);
        }
    }
}
