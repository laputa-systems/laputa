#include <elf.h>
#include <stdint.h>
#include <asm/bitsperlong.h>
#include <linux/kernel.h>

struct syscalltbl {
       const char *const *num_to_name;
       const uint16_t *sorted_names;
       uint16_t e_machine;
       uint16_t num_to_name_len;
       uint16_t sorted_names_len;
};

#if defined(ALL_SYSCALLTBL) || defined(__alpha__)
static const char *const syscall_num_to_name_EM_ALPHA[] = {
	[0] = "osf_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "osf_old_open",
	[6] = "close",
	[7] = "osf_wait4",
	[8] = "osf_old_creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "osf_execve",
	[12] = "chdir",
	[13] = "fchdir",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "chown",
	[17] = "brk",
	[18] = "osf_getfsstat",
	[19] = "lseek",
	[20] = "getxpid",
	[21] = "osf_mount",
	[22] = "umount2",
	[23] = "setuid",
	[24] = "getxuid",
	[25] = "exec_with_loader",
	[26] = "ptrace",
	[27] = "osf_nrecvmsg",
	[28] = "osf_nsendmsg",
	[29] = "osf_nrecvfrom",
	[30] = "osf_naccept",
	[31] = "osf_ngetpeername",
	[32] = "osf_ngetsockname",
	[33] = "access",
	[34] = "osf_chflags",
	[35] = "osf_fchflags",
	[36] = "sync",
	[37] = "kill",
	[38] = "osf_old_stat",
	[39] = "setpgid",
	[40] = "osf_old_lstat",
	[41] = "dup",
	[42] = "pipe",
	[43] = "osf_set_program_attributes",
	[44] = "osf_profil",
	[45] = "open",
	[46] = "osf_old_sigaction",
	[47] = "getxgid",
	[48] = "osf_sigprocmask",
	[49] = "osf_getlogin",
	[50] = "osf_setlogin",
	[51] = "acct",
	[52] = "sigpending",
	[54] = "ioctl",
	[55] = "osf_reboot",
	[56] = "osf_revoke",
	[57] = "symlink",
	[58] = "readlink",
	[59] = "execve",
	[60] = "umask",
	[61] = "chroot",
	[62] = "osf_old_fstat",
	[63] = "getpgrp",
	[64] = "getpagesize",
	[65] = "osf_mremap",
	[66] = "vfork",
	[67] = "stat",
	[68] = "lstat",
	[69] = "osf_sbrk",
	[70] = "osf_sstk",
	[71] = "mmap",
	[72] = "osf_old_vadvise",
	[73] = "munmap",
	[74] = "mprotect",
	[75] = "madvise",
	[76] = "vhangup",
	[77] = "osf_kmodcall",
	[78] = "osf_mincore",
	[79] = "getgroups",
	[80] = "setgroups",
	[81] = "osf_old_getpgrp",
	[82] = "setpgrp",
	[83] = "osf_setitimer",
	[84] = "osf_old_wait",
	[85] = "osf_table",
	[86] = "osf_getitimer",
	[87] = "gethostname",
	[88] = "sethostname",
	[89] = "getdtablesize",
	[90] = "dup2",
	[91] = "fstat",
	[92] = "fcntl",
	[93] = "osf_select",
	[94] = "poll",
	[95] = "fsync",
	[96] = "setpriority",
	[97] = "socket",
	[98] = "connect",
	[99] = "accept",
	[100] = "getpriority",
	[101] = "send",
	[102] = "recv",
	[103] = "sigreturn",
	[104] = "bind",
	[105] = "setsockopt",
	[106] = "listen",
	[107] = "osf_plock",
	[108] = "osf_old_sigvec",
	[109] = "osf_old_sigblock",
	[110] = "osf_old_sigsetmask",
	[111] = "sigsuspend",
	[112] = "osf_sigstack",
	[113] = "recvmsg",
	[114] = "sendmsg",
	[115] = "osf_old_vtrace",
	[116] = "osf_gettimeofday",
	[117] = "osf_getrusage",
	[118] = "getsockopt",
	[120] = "readv",
	[121] = "writev",
	[122] = "osf_settimeofday",
	[123] = "fchown",
	[124] = "fchmod",
	[125] = "recvfrom",
	[126] = "setreuid",
	[127] = "setregid",
	[128] = "rename",
	[129] = "truncate",
	[130] = "ftruncate",
	[131] = "flock",
	[132] = "setgid",
	[133] = "sendto",
	[134] = "shutdown",
	[135] = "socketpair",
	[136] = "mkdir",
	[137] = "rmdir",
	[138] = "osf_utimes",
	[139] = "osf_old_sigreturn",
	[140] = "osf_adjtime",
	[141] = "getpeername",
	[142] = "osf_gethostid",
	[143] = "osf_sethostid",
	[144] = "getrlimit",
	[145] = "setrlimit",
	[146] = "osf_old_killpg",
	[147] = "setsid",
	[148] = "quotactl",
	[149] = "osf_oldquota",
	[150] = "getsockname",
	[153] = "osf_pid_block",
	[154] = "osf_pid_unblock",
	[156] = "sigaction",
	[157] = "osf_sigwaitprim",
	[158] = "osf_nfssvc",
	[159] = "osf_getdirentries",
	[160] = "osf_statfs",
	[161] = "osf_fstatfs",
	[163] = "osf_asynch_daemon",
	[164] = "osf_getfh",
	[165] = "osf_getdomainname",
	[166] = "setdomainname",
	[169] = "osf_exportfs",
	[181] = "osf_alt_plock",
	[184] = "osf_getmnt",
	[187] = "osf_alt_sigpending",
	[188] = "osf_alt_setsid",
	[199] = "osf_swapon",
	[200] = "msgctl",
	[201] = "msgget",
	[202] = "msgrcv",
	[203] = "msgsnd",
	[204] = "semctl",
	[205] = "semget",
	[206] = "semop",
	[207] = "osf_utsname",
	[208] = "lchown",
	[209] = "shmat",
	[210] = "shmctl",
	[211] = "shmdt",
	[212] = "shmget",
	[213] = "osf_mvalid",
	[214] = "osf_getaddressconf",
	[215] = "osf_msleep",
	[216] = "osf_mwakeup",
	[217] = "msync",
	[218] = "osf_signal",
	[219] = "osf_utc_gettime",
	[220] = "osf_utc_adjtime",
	[222] = "osf_security",
	[223] = "osf_kloadcall",
	[224] = "osf_stat",
	[225] = "osf_lstat",
	[226] = "osf_fstat",
	[227] = "osf_statfs64",
	[228] = "osf_fstatfs64",
	[233] = "getpgid",
	[234] = "getsid",
	[235] = "sigaltstack",
	[236] = "osf_waitid",
	[237] = "osf_priocntlset",
	[238] = "osf_sigsendset",
	[239] = "osf_set_speculative",
	[240] = "osf_msfs_syscall",
	[241] = "osf_sysinfo",
	[242] = "osf_uadmin",
	[243] = "osf_fuser",
	[244] = "osf_proplist_syscall",
	[245] = "osf_ntp_adjtime",
	[246] = "osf_ntp_gettime",
	[247] = "osf_pathconf",
	[248] = "osf_fpathconf",
	[250] = "osf_uswitch",
	[251] = "osf_usleep_thread",
	[252] = "osf_audcntl",
	[253] = "osf_audgen",
	[254] = "sysfs",
	[255] = "osf_subsys_info",
	[256] = "osf_getsysinfo",
	[257] = "osf_setsysinfo",
	[258] = "osf_afs_syscall",
	[259] = "osf_swapctl",
	[260] = "osf_memcntl",
	[261] = "osf_fdatasync",
	[300] = "bdflush",
	[301] = "sethae",
	[302] = "mount",
	[303] = "old_adjtimex",
	[304] = "swapoff",
	[305] = "getdents",
	[306] = "create_module",
	[307] = "init_module",
	[308] = "delete_module",
	[309] = "get_kernel_syms",
	[310] = "syslog",
	[311] = "reboot",
	[312] = "clone",
	[313] = "uselib",
	[314] = "mlock",
	[315] = "munlock",
	[316] = "mlockall",
	[317] = "munlockall",
	[318] = "sysinfo",
	[319] = "_sysctl",
	[321] = "oldumount",
	[322] = "swapon",
	[323] = "times",
	[324] = "personality",
	[325] = "setfsuid",
	[326] = "setfsgid",
	[327] = "ustat",
	[328] = "statfs",
	[329] = "fstatfs",
	[330] = "sched_setparam",
	[331] = "sched_getparam",
	[332] = "sched_setscheduler",
	[333] = "sched_getscheduler",
	[334] = "sched_yield",
	[335] = "sched_get_priority_max",
	[336] = "sched_get_priority_min",
	[337] = "sched_rr_get_interval",
	[338] = "afs_syscall",
	[339] = "uname",
	[340] = "nanosleep",
	[341] = "mremap",
	[342] = "nfsservctl",
	[343] = "setresuid",
	[344] = "getresuid",
	[345] = "pciconfig_read",
	[346] = "pciconfig_write",
	[347] = "query_module",
	[348] = "prctl",
	[349] = "pread64",
	[350] = "pwrite64",
	[351] = "rt_sigreturn",
	[352] = "rt_sigaction",
	[353] = "rt_sigprocmask",
	[354] = "rt_sigpending",
	[355] = "rt_sigtimedwait",
	[356] = "rt_sigqueueinfo",
	[357] = "rt_sigsuspend",
	[358] = "select",
	[359] = "gettimeofday",
	[360] = "settimeofday",
	[361] = "getitimer",
	[362] = "setitimer",
	[363] = "utimes",
	[364] = "getrusage",
	[365] = "wait4",
	[366] = "adjtimex",
	[367] = "getcwd",
	[368] = "capget",
	[369] = "capset",
	[370] = "sendfile",
	[371] = "setresgid",
	[372] = "getresgid",
	[373] = "dipc",
	[374] = "pivot_root",
	[375] = "mincore",
	[376] = "pciconfig_iobase",
	[377] = "getdents64",
	[378] = "gettid",
	[379] = "readahead",
	[381] = "tkill",
	[382] = "setxattr",
	[383] = "lsetxattr",
	[384] = "fsetxattr",
	[385] = "getxattr",
	[386] = "lgetxattr",
	[387] = "fgetxattr",
	[388] = "listxattr",
	[389] = "llistxattr",
	[390] = "flistxattr",
	[391] = "removexattr",
	[392] = "lremovexattr",
	[393] = "fremovexattr",
	[394] = "futex",
	[395] = "sched_setaffinity",
	[396] = "sched_getaffinity",
	[397] = "tuxcall",
	[398] = "io_setup",
	[399] = "io_destroy",
	[400] = "io_getevents",
	[401] = "io_submit",
	[402] = "io_cancel",
	[405] = "exit_group",
	[406] = "lookup_dcookie",
	[407] = "epoll_create",
	[408] = "epoll_ctl",
	[409] = "epoll_wait",
	[410] = "remap_file_pages",
	[411] = "set_tid_address",
	[412] = "restart_syscall",
	[413] = "fadvise64",
	[414] = "timer_create",
	[415] = "timer_settime",
	[416] = "timer_gettime",
	[417] = "timer_getoverrun",
	[418] = "timer_delete",
	[419] = "clock_settime",
	[420] = "clock_gettime",
	[421] = "clock_getres",
	[422] = "clock_nanosleep",
	[423] = "semtimedop",
	[424] = "tgkill",
	[425] = "stat64",
	[426] = "lstat64",
	[427] = "fstat64",
	[428] = "vserver",
	[429] = "mbind",
	[430] = "get_mempolicy",
	[431] = "set_mempolicy",
	[432] = "mq_open",
	[433] = "mq_unlink",
	[434] = "mq_timedsend",
	[435] = "mq_timedreceive",
	[436] = "mq_notify",
	[437] = "mq_getsetattr",
	[438] = "waitid",
	[439] = "add_key",
	[440] = "request_key",
	[441] = "keyctl",
	[442] = "ioprio_set",
	[443] = "ioprio_get",
	[444] = "inotify_init",
	[445] = "inotify_add_watch",
	[446] = "inotify_rm_watch",
	[447] = "fdatasync",
	[448] = "kexec_load",
	[449] = "migrate_pages",
	[450] = "openat",
	[451] = "mkdirat",
	[452] = "mknodat",
	[453] = "fchownat",
	[454] = "futimesat",
	[455] = "fstatat64",
	[456] = "unlinkat",
	[457] = "renameat",
	[458] = "linkat",
	[459] = "symlinkat",
	[460] = "readlinkat",
	[461] = "fchmodat",
	[462] = "faccessat",
	[463] = "pselect6",
	[464] = "ppoll",
	[465] = "unshare",
	[466] = "set_robust_list",
	[467] = "get_robust_list",
	[468] = "splice",
	[469] = "sync_file_range",
	[470] = "tee",
	[471] = "vmsplice",
	[472] = "move_pages",
	[473] = "getcpu",
	[474] = "epoll_pwait",
	[475] = "utimensat",
	[476] = "signalfd",
	[477] = "timerfd",
	[478] = "eventfd",
	[479] = "recvmmsg",
	[480] = "fallocate",
	[481] = "timerfd_create",
	[482] = "timerfd_settime",
	[483] = "timerfd_gettime",
	[484] = "signalfd4",
	[485] = "eventfd2",
	[486] = "epoll_create1",
	[487] = "dup3",
	[488] = "pipe2",
	[489] = "inotify_init1",
	[490] = "preadv",
	[491] = "pwritev",
	[492] = "rt_tgsigqueueinfo",
	[493] = "perf_event_open",
	[494] = "fanotify_init",
	[495] = "fanotify_mark",
	[496] = "prlimit64",
	[497] = "name_to_handle_at",
	[498] = "open_by_handle_at",
	[499] = "clock_adjtime",
	[500] = "syncfs",
	[501] = "setns",
	[502] = "accept4",
	[503] = "sendmmsg",
	[504] = "process_vm_readv",
	[505] = "process_vm_writev",
	[506] = "kcmp",
	[507] = "finit_module",
	[508] = "sched_setattr",
	[509] = "sched_getattr",
	[510] = "renameat2",
	[511] = "getrandom",
	[512] = "memfd_create",
	[513] = "execveat",
	[514] = "seccomp",
	[515] = "bpf",
	[516] = "userfaultfd",
	[517] = "membarrier",
	[518] = "mlock2",
	[519] = "copy_file_range",
	[520] = "preadv2",
	[521] = "pwritev2",
	[522] = "statx",
	[523] = "io_pgetevents",
	[524] = "pkey_mprotect",
	[525] = "pkey_alloc",
	[526] = "pkey_free",
	[527] = "rseq",
	[528] = "statfs64",
	[529] = "fstatfs64",
	[530] = "getegid",
	[531] = "geteuid",
	[532] = "getppid",
	[534] = "pidfd_send_signal",
	[535] = "io_uring_setup",
	[536] = "io_uring_enter",
	[537] = "io_uring_register",
	[538] = "open_tree",
	[539] = "move_mount",
	[540] = "fsopen",
	[541] = "fsconfig",
	[542] = "fsmount",
	[543] = "fspick",
	[544] = "pidfd_open",
	[545] = "clone3",
	[546] = "close_range",
	[547] = "openat2",
	[548] = "pidfd_getfd",
	[549] = "faccessat2",
	[550] = "process_madvise",
	[551] = "epoll_pwait2",
	[552] = "mount_setattr",
	[553] = "quotactl_fd",
	[554] = "landlock_create_ruleset",
	[555] = "landlock_add_rule",
	[556] = "landlock_restrict_self",
	[558] = "process_mrelease",
	[559] = "futex_waitv",
	[560] = "set_mempolicy_home_node",
	[561] = "cachestat",
	[562] = "fchmodat2",
	[563] = "map_shadow_stack",
	[564] = "futex_wake",
	[565] = "futex_wait",
	[566] = "futex_requeue",
	[567] = "statmount",
	[568] = "listmount",
	[569] = "lsm_get_self_attr",
	[570] = "lsm_set_self_attr",
	[571] = "lsm_list_modules",
	[572] = "mseal",
};
static const uint16_t syscall_sorted_names_EM_ALPHA[] = {
	319,	/* _sysctl */
	99,	/* accept */
	502,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	439,	/* add_key */
	366,	/* adjtimex */
	338,	/* afs_syscall */
	300,	/* bdflush */
	104,	/* bind */
	515,	/* bpf */
	17,	/* brk */
	561,	/* cachestat */
	368,	/* capget */
	369,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	16,	/* chown */
	61,	/* chroot */
	499,	/* clock_adjtime */
	421,	/* clock_getres */
	420,	/* clock_gettime */
	422,	/* clock_nanosleep */
	419,	/* clock_settime */
	312,	/* clone */
	545,	/* clone3 */
	6,	/* close */
	546,	/* close_range */
	98,	/* connect */
	519,	/* copy_file_range */
	306,	/* create_module */
	308,	/* delete_module */
	373,	/* dipc */
	41,	/* dup */
	90,	/* dup2 */
	487,	/* dup3 */
	407,	/* epoll_create */
	486,	/* epoll_create1 */
	408,	/* epoll_ctl */
	474,	/* epoll_pwait */
	551,	/* epoll_pwait2 */
	409,	/* epoll_wait */
	478,	/* eventfd */
	485,	/* eventfd2 */
	25,	/* exec_with_loader */
	59,	/* execve */
	513,	/* execveat */
	1,	/* exit */
	405,	/* exit_group */
	462,	/* faccessat */
	549,	/* faccessat2 */
	413,	/* fadvise64 */
	480,	/* fallocate */
	494,	/* fanotify_init */
	495,	/* fanotify_mark */
	13,	/* fchdir */
	124,	/* fchmod */
	461,	/* fchmodat */
	562,	/* fchmodat2 */
	123,	/* fchown */
	453,	/* fchownat */
	92,	/* fcntl */
	447,	/* fdatasync */
	387,	/* fgetxattr */
	507,	/* finit_module */
	390,	/* flistxattr */
	131,	/* flock */
	2,	/* fork */
	393,	/* fremovexattr */
	541,	/* fsconfig */
	384,	/* fsetxattr */
	542,	/* fsmount */
	540,	/* fsopen */
	543,	/* fspick */
	91,	/* fstat */
	427,	/* fstat64 */
	455,	/* fstatat64 */
	329,	/* fstatfs */
	529,	/* fstatfs64 */
	95,	/* fsync */
	130,	/* ftruncate */
	394,	/* futex */
	566,	/* futex_requeue */
	565,	/* futex_wait */
	559,	/* futex_waitv */
	564,	/* futex_wake */
	454,	/* futimesat */
	309,	/* get_kernel_syms */
	430,	/* get_mempolicy */
	467,	/* get_robust_list */
	473,	/* getcpu */
	367,	/* getcwd */
	305,	/* getdents */
	377,	/* getdents64 */
	89,	/* getdtablesize */
	530,	/* getegid */
	531,	/* geteuid */
	79,	/* getgroups */
	87,	/* gethostname */
	361,	/* getitimer */
	64,	/* getpagesize */
	141,	/* getpeername */
	233,	/* getpgid */
	63,	/* getpgrp */
	532,	/* getppid */
	100,	/* getpriority */
	511,	/* getrandom */
	372,	/* getresgid */
	344,	/* getresuid */
	144,	/* getrlimit */
	364,	/* getrusage */
	234,	/* getsid */
	150,	/* getsockname */
	118,	/* getsockopt */
	378,	/* gettid */
	359,	/* gettimeofday */
	385,	/* getxattr */
	47,	/* getxgid */
	20,	/* getxpid */
	24,	/* getxuid */
	307,	/* init_module */
	445,	/* inotify_add_watch */
	444,	/* inotify_init */
	489,	/* inotify_init1 */
	446,	/* inotify_rm_watch */
	402,	/* io_cancel */
	399,	/* io_destroy */
	400,	/* io_getevents */
	523,	/* io_pgetevents */
	398,	/* io_setup */
	401,	/* io_submit */
	536,	/* io_uring_enter */
	537,	/* io_uring_register */
	535,	/* io_uring_setup */
	54,	/* ioctl */
	443,	/* ioprio_get */
	442,	/* ioprio_set */
	506,	/* kcmp */
	448,	/* kexec_load */
	441,	/* keyctl */
	37,	/* kill */
	555,	/* landlock_add_rule */
	554,	/* landlock_create_ruleset */
	556,	/* landlock_restrict_self */
	208,	/* lchown */
	386,	/* lgetxattr */
	9,	/* link */
	458,	/* linkat */
	106,	/* listen */
	568,	/* listmount */
	388,	/* listxattr */
	389,	/* llistxattr */
	406,	/* lookup_dcookie */
	392,	/* lremovexattr */
	19,	/* lseek */
	383,	/* lsetxattr */
	569,	/* lsm_get_self_attr */
	571,	/* lsm_list_modules */
	570,	/* lsm_set_self_attr */
	68,	/* lstat */
	426,	/* lstat64 */
	75,	/* madvise */
	563,	/* map_shadow_stack */
	429,	/* mbind */
	517,	/* membarrier */
	512,	/* memfd_create */
	449,	/* migrate_pages */
	375,	/* mincore */
	136,	/* mkdir */
	451,	/* mkdirat */
	14,	/* mknod */
	452,	/* mknodat */
	314,	/* mlock */
	518,	/* mlock2 */
	316,	/* mlockall */
	71,	/* mmap */
	302,	/* mount */
	552,	/* mount_setattr */
	539,	/* move_mount */
	472,	/* move_pages */
	74,	/* mprotect */
	437,	/* mq_getsetattr */
	436,	/* mq_notify */
	432,	/* mq_open */
	435,	/* mq_timedreceive */
	434,	/* mq_timedsend */
	433,	/* mq_unlink */
	341,	/* mremap */
	572,	/* mseal */
	200,	/* msgctl */
	201,	/* msgget */
	202,	/* msgrcv */
	203,	/* msgsnd */
	217,	/* msync */
	315,	/* munlock */
	317,	/* munlockall */
	73,	/* munmap */
	497,	/* name_to_handle_at */
	340,	/* nanosleep */
	342,	/* nfsservctl */
	303,	/* old_adjtimex */
	321,	/* oldumount */
	45,	/* open */
	498,	/* open_by_handle_at */
	538,	/* open_tree */
	450,	/* openat */
	547,	/* openat2 */
	140,	/* osf_adjtime */
	258,	/* osf_afs_syscall */
	181,	/* osf_alt_plock */
	188,	/* osf_alt_setsid */
	187,	/* osf_alt_sigpending */
	163,	/* osf_asynch_daemon */
	252,	/* osf_audcntl */
	253,	/* osf_audgen */
	34,	/* osf_chflags */
	11,	/* osf_execve */
	169,	/* osf_exportfs */
	35,	/* osf_fchflags */
	261,	/* osf_fdatasync */
	248,	/* osf_fpathconf */
	226,	/* osf_fstat */
	161,	/* osf_fstatfs */
	228,	/* osf_fstatfs64 */
	243,	/* osf_fuser */
	214,	/* osf_getaddressconf */
	159,	/* osf_getdirentries */
	165,	/* osf_getdomainname */
	164,	/* osf_getfh */
	18,	/* osf_getfsstat */
	142,	/* osf_gethostid */
	86,	/* osf_getitimer */
	49,	/* osf_getlogin */
	184,	/* osf_getmnt */
	117,	/* osf_getrusage */
	256,	/* osf_getsysinfo */
	116,	/* osf_gettimeofday */
	223,	/* osf_kloadcall */
	77,	/* osf_kmodcall */
	225,	/* osf_lstat */
	260,	/* osf_memcntl */
	78,	/* osf_mincore */
	21,	/* osf_mount */
	65,	/* osf_mremap */
	240,	/* osf_msfs_syscall */
	215,	/* osf_msleep */
	213,	/* osf_mvalid */
	216,	/* osf_mwakeup */
	30,	/* osf_naccept */
	158,	/* osf_nfssvc */
	31,	/* osf_ngetpeername */
	32,	/* osf_ngetsockname */
	29,	/* osf_nrecvfrom */
	27,	/* osf_nrecvmsg */
	28,	/* osf_nsendmsg */
	245,	/* osf_ntp_adjtime */
	246,	/* osf_ntp_gettime */
	8,	/* osf_old_creat */
	62,	/* osf_old_fstat */
	81,	/* osf_old_getpgrp */
	146,	/* osf_old_killpg */
	40,	/* osf_old_lstat */
	5,	/* osf_old_open */
	46,	/* osf_old_sigaction */
	109,	/* osf_old_sigblock */
	139,	/* osf_old_sigreturn */
	110,	/* osf_old_sigsetmask */
	108,	/* osf_old_sigvec */
	38,	/* osf_old_stat */
	72,	/* osf_old_vadvise */
	115,	/* osf_old_vtrace */
	84,	/* osf_old_wait */
	149,	/* osf_oldquota */
	247,	/* osf_pathconf */
	153,	/* osf_pid_block */
	154,	/* osf_pid_unblock */
	107,	/* osf_plock */
	237,	/* osf_priocntlset */
	44,	/* osf_profil */
	244,	/* osf_proplist_syscall */
	55,	/* osf_reboot */
	56,	/* osf_revoke */
	69,	/* osf_sbrk */
	222,	/* osf_security */
	93,	/* osf_select */
	43,	/* osf_set_program_attributes */
	239,	/* osf_set_speculative */
	143,	/* osf_sethostid */
	83,	/* osf_setitimer */
	50,	/* osf_setlogin */
	257,	/* osf_setsysinfo */
	122,	/* osf_settimeofday */
	218,	/* osf_signal */
	48,	/* osf_sigprocmask */
	238,	/* osf_sigsendset */
	112,	/* osf_sigstack */
	157,	/* osf_sigwaitprim */
	70,	/* osf_sstk */
	224,	/* osf_stat */
	160,	/* osf_statfs */
	227,	/* osf_statfs64 */
	255,	/* osf_subsys_info */
	259,	/* osf_swapctl */
	199,	/* osf_swapon */
	0,	/* osf_syscall */
	241,	/* osf_sysinfo */
	85,	/* osf_table */
	242,	/* osf_uadmin */
	251,	/* osf_usleep_thread */
	250,	/* osf_uswitch */
	220,	/* osf_utc_adjtime */
	219,	/* osf_utc_gettime */
	138,	/* osf_utimes */
	207,	/* osf_utsname */
	7,	/* osf_wait4 */
	236,	/* osf_waitid */
	376,	/* pciconfig_iobase */
	345,	/* pciconfig_read */
	346,	/* pciconfig_write */
	493,	/* perf_event_open */
	324,	/* personality */
	548,	/* pidfd_getfd */
	544,	/* pidfd_open */
	534,	/* pidfd_send_signal */
	42,	/* pipe */
	488,	/* pipe2 */
	374,	/* pivot_root */
	525,	/* pkey_alloc */
	526,	/* pkey_free */
	524,	/* pkey_mprotect */
	94,	/* poll */
	464,	/* ppoll */
	348,	/* prctl */
	349,	/* pread64 */
	490,	/* preadv */
	520,	/* preadv2 */
	496,	/* prlimit64 */
	550,	/* process_madvise */
	558,	/* process_mrelease */
	504,	/* process_vm_readv */
	505,	/* process_vm_writev */
	463,	/* pselect6 */
	26,	/* ptrace */
	350,	/* pwrite64 */
	491,	/* pwritev */
	521,	/* pwritev2 */
	347,	/* query_module */
	148,	/* quotactl */
	553,	/* quotactl_fd */
	3,	/* read */
	379,	/* readahead */
	58,	/* readlink */
	460,	/* readlinkat */
	120,	/* readv */
	311,	/* reboot */
	102,	/* recv */
	125,	/* recvfrom */
	479,	/* recvmmsg */
	113,	/* recvmsg */
	410,	/* remap_file_pages */
	391,	/* removexattr */
	128,	/* rename */
	457,	/* renameat */
	510,	/* renameat2 */
	440,	/* request_key */
	412,	/* restart_syscall */
	137,	/* rmdir */
	527,	/* rseq */
	352,	/* rt_sigaction */
	354,	/* rt_sigpending */
	353,	/* rt_sigprocmask */
	356,	/* rt_sigqueueinfo */
	351,	/* rt_sigreturn */
	357,	/* rt_sigsuspend */
	355,	/* rt_sigtimedwait */
	492,	/* rt_tgsigqueueinfo */
	335,	/* sched_get_priority_max */
	336,	/* sched_get_priority_min */
	396,	/* sched_getaffinity */
	509,	/* sched_getattr */
	331,	/* sched_getparam */
	333,	/* sched_getscheduler */
	337,	/* sched_rr_get_interval */
	395,	/* sched_setaffinity */
	508,	/* sched_setattr */
	330,	/* sched_setparam */
	332,	/* sched_setscheduler */
	334,	/* sched_yield */
	514,	/* seccomp */
	358,	/* select */
	204,	/* semctl */
	205,	/* semget */
	206,	/* semop */
	423,	/* semtimedop */
	101,	/* send */
	370,	/* sendfile */
	503,	/* sendmmsg */
	114,	/* sendmsg */
	133,	/* sendto */
	431,	/* set_mempolicy */
	560,	/* set_mempolicy_home_node */
	466,	/* set_robust_list */
	411,	/* set_tid_address */
	166,	/* setdomainname */
	326,	/* setfsgid */
	325,	/* setfsuid */
	132,	/* setgid */
	80,	/* setgroups */
	301,	/* sethae */
	88,	/* sethostname */
	362,	/* setitimer */
	501,	/* setns */
	39,	/* setpgid */
	82,	/* setpgrp */
	96,	/* setpriority */
	127,	/* setregid */
	371,	/* setresgid */
	343,	/* setresuid */
	126,	/* setreuid */
	145,	/* setrlimit */
	147,	/* setsid */
	105,	/* setsockopt */
	360,	/* settimeofday */
	23,	/* setuid */
	382,	/* setxattr */
	209,	/* shmat */
	210,	/* shmctl */
	211,	/* shmdt */
	212,	/* shmget */
	134,	/* shutdown */
	156,	/* sigaction */
	235,	/* sigaltstack */
	476,	/* signalfd */
	484,	/* signalfd4 */
	52,	/* sigpending */
	103,	/* sigreturn */
	111,	/* sigsuspend */
	97,	/* socket */
	135,	/* socketpair */
	468,	/* splice */
	67,	/* stat */
	425,	/* stat64 */
	328,	/* statfs */
	528,	/* statfs64 */
	567,	/* statmount */
	522,	/* statx */
	304,	/* swapoff */
	322,	/* swapon */
	57,	/* symlink */
	459,	/* symlinkat */
	36,	/* sync */
	469,	/* sync_file_range */
	500,	/* syncfs */
	254,	/* sysfs */
	318,	/* sysinfo */
	310,	/* syslog */
	470,	/* tee */
	424,	/* tgkill */
	414,	/* timer_create */
	418,	/* timer_delete */
	417,	/* timer_getoverrun */
	416,	/* timer_gettime */
	415,	/* timer_settime */
	477,	/* timerfd */
	481,	/* timerfd_create */
	483,	/* timerfd_gettime */
	482,	/* timerfd_settime */
	323,	/* times */
	381,	/* tkill */
	129,	/* truncate */
	397,	/* tuxcall */
	60,	/* umask */
	22,	/* umount2 */
	339,	/* uname */
	10,	/* unlink */
	456,	/* unlinkat */
	465,	/* unshare */
	313,	/* uselib */
	516,	/* userfaultfd */
	327,	/* ustat */
	475,	/* utimensat */
	363,	/* utimes */
	66,	/* vfork */
	76,	/* vhangup */
	471,	/* vmsplice */
	428,	/* vserver */
	365,	/* wait4 */
	438,	/* waitid */
	4,	/* write */
	121,	/* writev */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__alpha__)

#if defined(ALL_SYSCALLTBL) || defined(__arm__) || defined(__aarch64__)
static const char *const syscall_num_to_name_EM_ARM[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execve",
	[12] = "chdir",
	[13] = "time",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "mount",
	[22] = "umount",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "stime",
	[26] = "ptrace",
	[27] = "alarm",
	[29] = "pause",
	[30] = "utime",
	[33] = "access",
	[34] = "nice",
	[36] = "sync",
	[37] = "kill",
	[38] = "rename",
	[39] = "mkdir",
	[40] = "rmdir",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[45] = "brk",
	[46] = "setgid",
	[47] = "getgid",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[52] = "umount2",
	[54] = "ioctl",
	[55] = "fcntl",
	[57] = "setpgid",
	[60] = "umask",
	[61] = "chroot",
	[62] = "ustat",
	[63] = "dup2",
	[64] = "getppid",
	[65] = "getpgrp",
	[66] = "setsid",
	[67] = "sigaction",
	[70] = "setreuid",
	[71] = "setregid",
	[72] = "sigsuspend",
	[73] = "sigpending",
	[74] = "sethostname",
	[75] = "setrlimit",
	[76] = "getrlimit",
	[77] = "getrusage",
	[78] = "gettimeofday",
	[79] = "settimeofday",
	[80] = "getgroups",
	[81] = "setgroups",
	[82] = "select",
	[83] = "symlink",
	[85] = "readlink",
	[86] = "uselib",
	[87] = "swapon",
	[88] = "reboot",
	[89] = "readdir",
	[90] = "mmap",
	[91] = "munmap",
	[92] = "truncate",
	[93] = "ftruncate",
	[94] = "fchmod",
	[95] = "fchown",
	[96] = "getpriority",
	[97] = "setpriority",
	[99] = "statfs",
	[100] = "fstatfs",
	[102] = "socketcall",
	[103] = "syslog",
	[104] = "setitimer",
	[105] = "getitimer",
	[106] = "stat",
	[107] = "lstat",
	[108] = "fstat",
	[111] = "vhangup",
	[113] = "syscall",
	[114] = "wait4",
	[115] = "swapoff",
	[116] = "sysinfo",
	[117] = "ipc",
	[118] = "fsync",
	[119] = "sigreturn",
	[120] = "clone",
	[121] = "setdomainname",
	[122] = "uname",
	[124] = "adjtimex",
	[125] = "mprotect",
	[126] = "sigprocmask",
	[128] = "init_module",
	[129] = "delete_module",
	[131] = "quotactl",
	[132] = "getpgid",
	[133] = "fchdir",
	[134] = "bdflush",
	[135] = "sysfs",
	[136] = "personality",
	[138] = "setfsuid",
	[139] = "setfsgid",
	[140] = "_llseek",
	[141] = "getdents",
	[142] = "_newselect",
	[143] = "flock",
	[144] = "msync",
	[145] = "readv",
	[146] = "writev",
	[147] = "getsid",
	[148] = "fdatasync",
	[149] = "_sysctl",
	[150] = "mlock",
	[151] = "munlock",
	[152] = "mlockall",
	[153] = "munlockall",
	[154] = "sched_setparam",
	[155] = "sched_getparam",
	[156] = "sched_setscheduler",
	[157] = "sched_getscheduler",
	[158] = "sched_yield",
	[159] = "sched_get_priority_max",
	[160] = "sched_get_priority_min",
	[161] = "sched_rr_get_interval",
	[162] = "nanosleep",
	[163] = "mremap",
	[164] = "setresuid",
	[165] = "getresuid",
	[168] = "poll",
	[169] = "nfsservctl",
	[170] = "setresgid",
	[171] = "getresgid",
	[172] = "prctl",
	[173] = "rt_sigreturn",
	[174] = "rt_sigaction",
	[175] = "rt_sigprocmask",
	[176] = "rt_sigpending",
	[177] = "rt_sigtimedwait",
	[178] = "rt_sigqueueinfo",
	[179] = "rt_sigsuspend",
	[180] = "pread64",
	[181] = "pwrite64",
	[182] = "chown",
	[183] = "getcwd",
	[184] = "capget",
	[185] = "capset",
	[186] = "sigaltstack",
	[187] = "sendfile",
	[190] = "vfork",
	[191] = "ugetrlimit",
	[192] = "mmap2",
	[193] = "truncate64",
	[194] = "ftruncate64",
	[195] = "stat64",
	[196] = "lstat64",
	[197] = "fstat64",
	[198] = "lchown32",
	[199] = "getuid32",
	[200] = "getgid32",
	[201] = "geteuid32",
	[202] = "getegid32",
	[203] = "setreuid32",
	[204] = "setregid32",
	[205] = "getgroups32",
	[206] = "setgroups32",
	[207] = "fchown32",
	[208] = "setresuid32",
	[209] = "getresuid32",
	[210] = "setresgid32",
	[211] = "getresgid32",
	[212] = "chown32",
	[213] = "setuid32",
	[214] = "setgid32",
	[215] = "setfsuid32",
	[216] = "setfsgid32",
	[217] = "getdents64",
	[218] = "pivot_root",
	[219] = "mincore",
	[220] = "madvise",
	[221] = "fcntl64",
	[224] = "gettid",
	[225] = "readahead",
	[226] = "setxattr",
	[227] = "lsetxattr",
	[228] = "fsetxattr",
	[229] = "getxattr",
	[230] = "lgetxattr",
	[231] = "fgetxattr",
	[232] = "listxattr",
	[233] = "llistxattr",
	[234] = "flistxattr",
	[235] = "removexattr",
	[236] = "lremovexattr",
	[237] = "fremovexattr",
	[238] = "tkill",
	[239] = "sendfile64",
	[240] = "futex",
	[241] = "sched_setaffinity",
	[242] = "sched_getaffinity",
	[243] = "io_setup",
	[244] = "io_destroy",
	[245] = "io_getevents",
	[246] = "io_submit",
	[247] = "io_cancel",
	[248] = "exit_group",
	[249] = "lookup_dcookie",
	[250] = "epoll_create",
	[251] = "epoll_ctl",
	[252] = "epoll_wait",
	[253] = "remap_file_pages",
	[256] = "set_tid_address",
	[257] = "timer_create",
	[258] = "timer_settime",
	[259] = "timer_gettime",
	[260] = "timer_getoverrun",
	[261] = "timer_delete",
	[262] = "clock_settime",
	[263] = "clock_gettime",
	[264] = "clock_getres",
	[265] = "clock_nanosleep",
	[266] = "statfs64",
	[267] = "fstatfs64",
	[268] = "tgkill",
	[269] = "utimes",
	[270] = "arm_fadvise64_64",
	[271] = "pciconfig_iobase",
	[272] = "pciconfig_read",
	[273] = "pciconfig_write",
	[274] = "mq_open",
	[275] = "mq_unlink",
	[276] = "mq_timedsend",
	[277] = "mq_timedreceive",
	[278] = "mq_notify",
	[279] = "mq_getsetattr",
	[280] = "waitid",
	[281] = "socket",
	[282] = "bind",
	[283] = "connect",
	[284] = "listen",
	[285] = "accept",
	[286] = "getsockname",
	[287] = "getpeername",
	[288] = "socketpair",
	[289] = "send",
	[290] = "sendto",
	[291] = "recv",
	[292] = "recvfrom",
	[293] = "shutdown",
	[294] = "setsockopt",
	[295] = "getsockopt",
	[296] = "sendmsg",
	[297] = "recvmsg",
	[298] = "semop",
	[299] = "semget",
	[300] = "semctl",
	[301] = "msgsnd",
	[302] = "msgrcv",
	[303] = "msgget",
	[304] = "msgctl",
	[305] = "shmat",
	[306] = "shmdt",
	[307] = "shmget",
	[308] = "shmctl",
	[309] = "add_key",
	[310] = "request_key",
	[311] = "keyctl",
	[312] = "semtimedop",
	[313] = "vserver",
	[314] = "ioprio_set",
	[315] = "ioprio_get",
	[316] = "inotify_init",
	[317] = "inotify_add_watch",
	[318] = "inotify_rm_watch",
	[319] = "mbind",
	[320] = "get_mempolicy",
	[321] = "set_mempolicy",
	[322] = "openat",
	[323] = "mkdirat",
	[324] = "mknodat",
	[325] = "fchownat",
	[326] = "futimesat",
	[327] = "fstatat64",
	[328] = "unlinkat",
	[329] = "renameat",
	[330] = "linkat",
	[331] = "symlinkat",
	[332] = "readlinkat",
	[333] = "fchmodat",
	[334] = "faccessat",
	[335] = "pselect6",
	[336] = "ppoll",
	[337] = "unshare",
	[338] = "set_robust_list",
	[339] = "get_robust_list",
	[340] = "splice",
	[341] = "arm_sync_file_range",
	[342] = "tee",
	[343] = "vmsplice",
	[344] = "move_pages",
	[345] = "getcpu",
	[346] = "epoll_pwait",
	[347] = "kexec_load",
	[348] = "utimensat",
	[349] = "signalfd",
	[350] = "timerfd_create",
	[351] = "eventfd",
	[352] = "fallocate",
	[353] = "timerfd_settime",
	[354] = "timerfd_gettime",
	[355] = "signalfd4",
	[356] = "eventfd2",
	[357] = "epoll_create1",
	[358] = "dup3",
	[359] = "pipe2",
	[360] = "inotify_init1",
	[361] = "preadv",
	[362] = "pwritev",
	[363] = "rt_tgsigqueueinfo",
	[364] = "perf_event_open",
	[365] = "recvmmsg",
	[366] = "accept4",
	[367] = "fanotify_init",
	[368] = "fanotify_mark",
	[369] = "prlimit64",
	[370] = "name_to_handle_at",
	[371] = "open_by_handle_at",
	[372] = "clock_adjtime",
	[373] = "syncfs",
	[374] = "sendmmsg",
	[375] = "setns",
	[376] = "process_vm_readv",
	[377] = "process_vm_writev",
	[378] = "kcmp",
	[379] = "finit_module",
	[380] = "sched_setattr",
	[381] = "sched_getattr",
	[382] = "renameat2",
	[383] = "seccomp",
	[384] = "getrandom",
	[385] = "memfd_create",
	[386] = "bpf",
	[387] = "execveat",
	[388] = "userfaultfd",
	[389] = "membarrier",
	[390] = "mlock2",
	[391] = "copy_file_range",
	[392] = "preadv2",
	[393] = "pwritev2",
	[394] = "pkey_mprotect",
	[395] = "pkey_alloc",
	[396] = "pkey_free",
	[397] = "statx",
	[398] = "rseq",
	[399] = "io_pgetevents",
	[400] = "migrate_pages",
	[401] = "kexec_file_load",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_ARM[] = {
	140,	/* _llseek */
	142,	/* _newselect */
	149,	/* _sysctl */
	285,	/* accept */
	366,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	309,	/* add_key */
	124,	/* adjtimex */
	27,	/* alarm */
	270,	/* arm_fadvise64_64 */
	341,	/* arm_sync_file_range */
	134,	/* bdflush */
	282,	/* bind */
	386,	/* bpf */
	45,	/* brk */
	451,	/* cachestat */
	184,	/* capget */
	185,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	182,	/* chown */
	212,	/* chown32 */
	61,	/* chroot */
	372,	/* clock_adjtime */
	405,	/* clock_adjtime64 */
	264,	/* clock_getres */
	406,	/* clock_getres_time64 */
	263,	/* clock_gettime */
	403,	/* clock_gettime64 */
	265,	/* clock_nanosleep */
	407,	/* clock_nanosleep_time64 */
	262,	/* clock_settime */
	404,	/* clock_settime64 */
	120,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	283,	/* connect */
	391,	/* copy_file_range */
	8,	/* creat */
	129,	/* delete_module */
	41,	/* dup */
	63,	/* dup2 */
	358,	/* dup3 */
	250,	/* epoll_create */
	357,	/* epoll_create1 */
	251,	/* epoll_ctl */
	346,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	252,	/* epoll_wait */
	351,	/* eventfd */
	356,	/* eventfd2 */
	11,	/* execve */
	387,	/* execveat */
	1,	/* exit */
	248,	/* exit_group */
	334,	/* faccessat */
	439,	/* faccessat2 */
	352,	/* fallocate */
	367,	/* fanotify_init */
	368,	/* fanotify_mark */
	133,	/* fchdir */
	94,	/* fchmod */
	333,	/* fchmodat */
	452,	/* fchmodat2 */
	95,	/* fchown */
	207,	/* fchown32 */
	325,	/* fchownat */
	55,	/* fcntl */
	221,	/* fcntl64 */
	148,	/* fdatasync */
	231,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	379,	/* finit_module */
	234,	/* flistxattr */
	143,	/* flock */
	2,	/* fork */
	237,	/* fremovexattr */
	431,	/* fsconfig */
	228,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	108,	/* fstat */
	197,	/* fstat64 */
	327,	/* fstatat64 */
	100,	/* fstatfs */
	267,	/* fstatfs64 */
	118,	/* fsync */
	93,	/* ftruncate */
	194,	/* ftruncate64 */
	240,	/* futex */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	326,	/* futimesat */
	320,	/* get_mempolicy */
	339,	/* get_robust_list */
	345,	/* getcpu */
	183,	/* getcwd */
	141,	/* getdents */
	217,	/* getdents64 */
	50,	/* getegid */
	202,	/* getegid32 */
	49,	/* geteuid */
	201,	/* geteuid32 */
	47,	/* getgid */
	200,	/* getgid32 */
	80,	/* getgroups */
	205,	/* getgroups32 */
	105,	/* getitimer */
	287,	/* getpeername */
	132,	/* getpgid */
	65,	/* getpgrp */
	20,	/* getpid */
	64,	/* getppid */
	96,	/* getpriority */
	384,	/* getrandom */
	171,	/* getresgid */
	211,	/* getresgid32 */
	165,	/* getresuid */
	209,	/* getresuid32 */
	76,	/* getrlimit */
	77,	/* getrusage */
	147,	/* getsid */
	286,	/* getsockname */
	295,	/* getsockopt */
	224,	/* gettid */
	78,	/* gettimeofday */
	24,	/* getuid */
	199,	/* getuid32 */
	229,	/* getxattr */
	464,	/* getxattrat */
	128,	/* init_module */
	317,	/* inotify_add_watch */
	316,	/* inotify_init */
	360,	/* inotify_init1 */
	318,	/* inotify_rm_watch */
	247,	/* io_cancel */
	244,	/* io_destroy */
	245,	/* io_getevents */
	399,	/* io_pgetevents */
	416,	/* io_pgetevents_time64 */
	243,	/* io_setup */
	246,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	315,	/* ioprio_get */
	314,	/* ioprio_set */
	117,	/* ipc */
	378,	/* kcmp */
	401,	/* kexec_file_load */
	347,	/* kexec_load */
	311,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	198,	/* lchown32 */
	230,	/* lgetxattr */
	9,	/* link */
	330,	/* linkat */
	284,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	232,	/* listxattr */
	465,	/* listxattrat */
	233,	/* llistxattr */
	249,	/* lookup_dcookie */
	236,	/* lremovexattr */
	19,	/* lseek */
	227,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	107,	/* lstat */
	196,	/* lstat64 */
	220,	/* madvise */
	453,	/* map_shadow_stack */
	319,	/* mbind */
	389,	/* membarrier */
	385,	/* memfd_create */
	400,	/* migrate_pages */
	219,	/* mincore */
	39,	/* mkdir */
	323,	/* mkdirat */
	14,	/* mknod */
	324,	/* mknodat */
	150,	/* mlock */
	390,	/* mlock2 */
	152,	/* mlockall */
	90,	/* mmap */
	192,	/* mmap2 */
	21,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	344,	/* move_pages */
	125,	/* mprotect */
	279,	/* mq_getsetattr */
	278,	/* mq_notify */
	274,	/* mq_open */
	277,	/* mq_timedreceive */
	419,	/* mq_timedreceive_time64 */
	276,	/* mq_timedsend */
	418,	/* mq_timedsend_time64 */
	275,	/* mq_unlink */
	163,	/* mremap */
	462,	/* mseal */
	304,	/* msgctl */
	303,	/* msgget */
	302,	/* msgrcv */
	301,	/* msgsnd */
	144,	/* msync */
	151,	/* munlock */
	153,	/* munlockall */
	91,	/* munmap */
	370,	/* name_to_handle_at */
	162,	/* nanosleep */
	169,	/* nfsservctl */
	34,	/* nice */
	5,	/* open */
	371,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	322,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	271,	/* pciconfig_iobase */
	272,	/* pciconfig_read */
	273,	/* pciconfig_write */
	364,	/* perf_event_open */
	136,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	359,	/* pipe2 */
	218,	/* pivot_root */
	395,	/* pkey_alloc */
	396,	/* pkey_free */
	394,	/* pkey_mprotect */
	168,	/* poll */
	336,	/* ppoll */
	414,	/* ppoll_time64 */
	172,	/* prctl */
	180,	/* pread64 */
	361,	/* preadv */
	392,	/* preadv2 */
	369,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	376,	/* process_vm_readv */
	377,	/* process_vm_writev */
	335,	/* pselect6 */
	413,	/* pselect6_time64 */
	26,	/* ptrace */
	181,	/* pwrite64 */
	362,	/* pwritev */
	393,	/* pwritev2 */
	131,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	225,	/* readahead */
	89,	/* readdir */
	85,	/* readlink */
	332,	/* readlinkat */
	145,	/* readv */
	88,	/* reboot */
	291,	/* recv */
	292,	/* recvfrom */
	365,	/* recvmmsg */
	417,	/* recvmmsg_time64 */
	297,	/* recvmsg */
	253,	/* remap_file_pages */
	235,	/* removexattr */
	466,	/* removexattrat */
	38,	/* rename */
	329,	/* renameat */
	382,	/* renameat2 */
	310,	/* request_key */
	0,	/* restart_syscall */
	40,	/* rmdir */
	398,	/* rseq */
	471,	/* rseq_slice_yield */
	174,	/* rt_sigaction */
	176,	/* rt_sigpending */
	175,	/* rt_sigprocmask */
	178,	/* rt_sigqueueinfo */
	173,	/* rt_sigreturn */
	179,	/* rt_sigsuspend */
	177,	/* rt_sigtimedwait */
	421,	/* rt_sigtimedwait_time64 */
	363,	/* rt_tgsigqueueinfo */
	159,	/* sched_get_priority_max */
	160,	/* sched_get_priority_min */
	242,	/* sched_getaffinity */
	381,	/* sched_getattr */
	155,	/* sched_getparam */
	157,	/* sched_getscheduler */
	161,	/* sched_rr_get_interval */
	423,	/* sched_rr_get_interval_time64 */
	241,	/* sched_setaffinity */
	380,	/* sched_setattr */
	154,	/* sched_setparam */
	156,	/* sched_setscheduler */
	158,	/* sched_yield */
	383,	/* seccomp */
	82,	/* select */
	300,	/* semctl */
	299,	/* semget */
	298,	/* semop */
	312,	/* semtimedop */
	420,	/* semtimedop_time64 */
	289,	/* send */
	187,	/* sendfile */
	239,	/* sendfile64 */
	374,	/* sendmmsg */
	296,	/* sendmsg */
	290,	/* sendto */
	321,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	338,	/* set_robust_list */
	256,	/* set_tid_address */
	121,	/* setdomainname */
	139,	/* setfsgid */
	216,	/* setfsgid32 */
	138,	/* setfsuid */
	215,	/* setfsuid32 */
	46,	/* setgid */
	214,	/* setgid32 */
	81,	/* setgroups */
	206,	/* setgroups32 */
	74,	/* sethostname */
	104,	/* setitimer */
	375,	/* setns */
	57,	/* setpgid */
	97,	/* setpriority */
	71,	/* setregid */
	204,	/* setregid32 */
	170,	/* setresgid */
	210,	/* setresgid32 */
	164,	/* setresuid */
	208,	/* setresuid32 */
	70,	/* setreuid */
	203,	/* setreuid32 */
	75,	/* setrlimit */
	66,	/* setsid */
	294,	/* setsockopt */
	79,	/* settimeofday */
	23,	/* setuid */
	213,	/* setuid32 */
	226,	/* setxattr */
	463,	/* setxattrat */
	305,	/* shmat */
	308,	/* shmctl */
	306,	/* shmdt */
	307,	/* shmget */
	293,	/* shutdown */
	67,	/* sigaction */
	186,	/* sigaltstack */
	349,	/* signalfd */
	355,	/* signalfd4 */
	73,	/* sigpending */
	126,	/* sigprocmask */
	119,	/* sigreturn */
	72,	/* sigsuspend */
	281,	/* socket */
	102,	/* socketcall */
	288,	/* socketpair */
	340,	/* splice */
	106,	/* stat */
	195,	/* stat64 */
	99,	/* statfs */
	266,	/* statfs64 */
	457,	/* statmount */
	397,	/* statx */
	25,	/* stime */
	115,	/* swapoff */
	87,	/* swapon */
	83,	/* symlink */
	331,	/* symlinkat */
	36,	/* sync */
	373,	/* syncfs */
	113,	/* syscall */
	135,	/* sysfs */
	116,	/* sysinfo */
	103,	/* syslog */
	342,	/* tee */
	268,	/* tgkill */
	13,	/* time */
	257,	/* timer_create */
	261,	/* timer_delete */
	260,	/* timer_getoverrun */
	259,	/* timer_gettime */
	408,	/* timer_gettime64 */
	258,	/* timer_settime */
	409,	/* timer_settime64 */
	350,	/* timerfd_create */
	354,	/* timerfd_gettime */
	410,	/* timerfd_gettime64 */
	353,	/* timerfd_settime */
	411,	/* timerfd_settime64 */
	43,	/* times */
	238,	/* tkill */
	92,	/* truncate */
	193,	/* truncate64 */
	191,	/* ugetrlimit */
	60,	/* umask */
	22,	/* umount */
	52,	/* umount2 */
	122,	/* uname */
	10,	/* unlink */
	328,	/* unlinkat */
	337,	/* unshare */
	86,	/* uselib */
	388,	/* userfaultfd */
	62,	/* ustat */
	30,	/* utime */
	348,	/* utimensat */
	412,	/* utimensat_time64 */
	269,	/* utimes */
	190,	/* vfork */
	111,	/* vhangup */
	343,	/* vmsplice */
	313,	/* vserver */
	114,	/* wait4 */
	280,	/* waitid */
	4,	/* write */
	146,	/* writev */
};
static const char *const syscall_num_to_name_EM_AARCH64[] = {
	[0] = "io_setup",
	[1] = "io_destroy",
	[2] = "io_submit",
	[3] = "io_cancel",
	[4] = "io_getevents",
	[5] = "setxattr",
	[6] = "lsetxattr",
	[7] = "fsetxattr",
	[8] = "getxattr",
	[9] = "lgetxattr",
	[10] = "fgetxattr",
	[11] = "listxattr",
	[12] = "llistxattr",
	[13] = "flistxattr",
	[14] = "removexattr",
	[15] = "lremovexattr",
	[16] = "fremovexattr",
	[17] = "getcwd",
	[18] = "lookup_dcookie",
	[19] = "eventfd2",
	[20] = "epoll_create1",
	[21] = "epoll_ctl",
	[22] = "epoll_pwait",
	[23] = "dup",
	[24] = "dup3",
	[25] = "fcntl",
	[26] = "inotify_init1",
	[27] = "inotify_add_watch",
	[28] = "inotify_rm_watch",
	[29] = "ioctl",
	[30] = "ioprio_set",
	[31] = "ioprio_get",
	[32] = "flock",
	[33] = "mknodat",
	[34] = "mkdirat",
	[35] = "unlinkat",
	[36] = "symlinkat",
	[37] = "linkat",
	[38] = "renameat",
	[39] = "umount2",
	[40] = "mount",
	[41] = "pivot_root",
	[42] = "nfsservctl",
	[43] = "statfs",
	[44] = "fstatfs",
	[45] = "truncate",
	[46] = "ftruncate",
	[47] = "fallocate",
	[48] = "faccessat",
	[49] = "chdir",
	[50] = "fchdir",
	[51] = "chroot",
	[52] = "fchmod",
	[53] = "fchmodat",
	[54] = "fchownat",
	[55] = "fchown",
	[56] = "openat",
	[57] = "close",
	[58] = "vhangup",
	[59] = "pipe2",
	[60] = "quotactl",
	[61] = "getdents64",
	[62] = "lseek",
	[63] = "read",
	[64] = "write",
	[65] = "readv",
	[66] = "writev",
	[67] = "pread64",
	[68] = "pwrite64",
	[69] = "preadv",
	[70] = "pwritev",
	[71] = "sendfile",
	[72] = "pselect6",
	[73] = "ppoll",
	[74] = "signalfd4",
	[75] = "vmsplice",
	[76] = "splice",
	[77] = "tee",
	[78] = "readlinkat",
	[79] = "newfstatat",
	[80] = "fstat",
	[81] = "sync",
	[82] = "fsync",
	[83] = "fdatasync",
	[84] = "sync_file_range",
	[85] = "timerfd_create",
	[86] = "timerfd_settime",
	[87] = "timerfd_gettime",
	[88] = "utimensat",
	[89] = "acct",
	[90] = "capget",
	[91] = "capset",
	[92] = "personality",
	[93] = "exit",
	[94] = "exit_group",
	[95] = "waitid",
	[96] = "set_tid_address",
	[97] = "unshare",
	[98] = "futex",
	[99] = "set_robust_list",
	[100] = "get_robust_list",
	[101] = "nanosleep",
	[102] = "getitimer",
	[103] = "setitimer",
	[104] = "kexec_load",
	[105] = "init_module",
	[106] = "delete_module",
	[107] = "timer_create",
	[108] = "timer_gettime",
	[109] = "timer_getoverrun",
	[110] = "timer_settime",
	[111] = "timer_delete",
	[112] = "clock_settime",
	[113] = "clock_gettime",
	[114] = "clock_getres",
	[115] = "clock_nanosleep",
	[116] = "syslog",
	[117] = "ptrace",
	[118] = "sched_setparam",
	[119] = "sched_setscheduler",
	[120] = "sched_getscheduler",
	[121] = "sched_getparam",
	[122] = "sched_setaffinity",
	[123] = "sched_getaffinity",
	[124] = "sched_yield",
	[125] = "sched_get_priority_max",
	[126] = "sched_get_priority_min",
	[127] = "sched_rr_get_interval",
	[128] = "restart_syscall",
	[129] = "kill",
	[130] = "tkill",
	[131] = "tgkill",
	[132] = "sigaltstack",
	[133] = "rt_sigsuspend",
	[134] = "rt_sigaction",
	[135] = "rt_sigprocmask",
	[136] = "rt_sigpending",
	[137] = "rt_sigtimedwait",
	[138] = "rt_sigqueueinfo",
	[139] = "rt_sigreturn",
	[140] = "setpriority",
	[141] = "getpriority",
	[142] = "reboot",
	[143] = "setregid",
	[144] = "setgid",
	[145] = "setreuid",
	[146] = "setuid",
	[147] = "setresuid",
	[148] = "getresuid",
	[149] = "setresgid",
	[150] = "getresgid",
	[151] = "setfsuid",
	[152] = "setfsgid",
	[153] = "times",
	[154] = "setpgid",
	[155] = "getpgid",
	[156] = "getsid",
	[157] = "setsid",
	[158] = "getgroups",
	[159] = "setgroups",
	[160] = "uname",
	[161] = "sethostname",
	[162] = "setdomainname",
	[163] = "getrlimit",
	[164] = "setrlimit",
	[165] = "getrusage",
	[166] = "umask",
	[167] = "prctl",
	[168] = "getcpu",
	[169] = "gettimeofday",
	[170] = "settimeofday",
	[171] = "adjtimex",
	[172] = "getpid",
	[173] = "getppid",
	[174] = "getuid",
	[175] = "geteuid",
	[176] = "getgid",
	[177] = "getegid",
	[178] = "gettid",
	[179] = "sysinfo",
	[180] = "mq_open",
	[181] = "mq_unlink",
	[182] = "mq_timedsend",
	[183] = "mq_timedreceive",
	[184] = "mq_notify",
	[185] = "mq_getsetattr",
	[186] = "msgget",
	[187] = "msgctl",
	[188] = "msgrcv",
	[189] = "msgsnd",
	[190] = "semget",
	[191] = "semctl",
	[192] = "semtimedop",
	[193] = "semop",
	[194] = "shmget",
	[195] = "shmctl",
	[196] = "shmat",
	[197] = "shmdt",
	[198] = "socket",
	[199] = "socketpair",
	[200] = "bind",
	[201] = "listen",
	[202] = "accept",
	[203] = "connect",
	[204] = "getsockname",
	[205] = "getpeername",
	[206] = "sendto",
	[207] = "recvfrom",
	[208] = "setsockopt",
	[209] = "getsockopt",
	[210] = "shutdown",
	[211] = "sendmsg",
	[212] = "recvmsg",
	[213] = "readahead",
	[214] = "brk",
	[215] = "munmap",
	[216] = "mremap",
	[217] = "add_key",
	[218] = "request_key",
	[219] = "keyctl",
	[220] = "clone",
	[221] = "execve",
	[222] = "mmap",
	[223] = "fadvise64",
	[224] = "swapon",
	[225] = "swapoff",
	[226] = "mprotect",
	[227] = "msync",
	[228] = "mlock",
	[229] = "munlock",
	[230] = "mlockall",
	[231] = "munlockall",
	[232] = "mincore",
	[233] = "madvise",
	[234] = "remap_file_pages",
	[235] = "mbind",
	[236] = "get_mempolicy",
	[237] = "set_mempolicy",
	[238] = "migrate_pages",
	[239] = "move_pages",
	[240] = "rt_tgsigqueueinfo",
	[241] = "perf_event_open",
	[242] = "accept4",
	[243] = "recvmmsg",
	[260] = "wait4",
	[261] = "prlimit64",
	[262] = "fanotify_init",
	[263] = "fanotify_mark",
	[264] = "name_to_handle_at",
	[265] = "open_by_handle_at",
	[266] = "clock_adjtime",
	[267] = "syncfs",
	[268] = "setns",
	[269] = "sendmmsg",
	[270] = "process_vm_readv",
	[271] = "process_vm_writev",
	[272] = "kcmp",
	[273] = "finit_module",
	[274] = "sched_setattr",
	[275] = "sched_getattr",
	[276] = "renameat2",
	[277] = "seccomp",
	[278] = "getrandom",
	[279] = "memfd_create",
	[280] = "bpf",
	[281] = "execveat",
	[282] = "userfaultfd",
	[283] = "membarrier",
	[284] = "mlock2",
	[285] = "copy_file_range",
	[286] = "preadv2",
	[287] = "pwritev2",
	[288] = "pkey_mprotect",
	[289] = "pkey_alloc",
	[290] = "pkey_free",
	[291] = "statx",
	[292] = "io_pgetevents",
	[293] = "rseq",
	[294] = "kexec_file_load",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[447] = "memfd_secret",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_AARCH64[] = {
	202,	/* accept */
	242,	/* accept4 */
	89,	/* acct */
	217,	/* add_key */
	171,	/* adjtimex */
	200,	/* bind */
	280,	/* bpf */
	214,	/* brk */
	451,	/* cachestat */
	90,	/* capget */
	91,	/* capset */
	49,	/* chdir */
	51,	/* chroot */
	266,	/* clock_adjtime */
	114,	/* clock_getres */
	113,	/* clock_gettime */
	115,	/* clock_nanosleep */
	112,	/* clock_settime */
	220,	/* clone */
	435,	/* clone3 */
	57,	/* close */
	436,	/* close_range */
	203,	/* connect */
	285,	/* copy_file_range */
	106,	/* delete_module */
	23,	/* dup */
	24,	/* dup3 */
	20,	/* epoll_create1 */
	21,	/* epoll_ctl */
	22,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	19,	/* eventfd2 */
	221,	/* execve */
	281,	/* execveat */
	93,	/* exit */
	94,	/* exit_group */
	48,	/* faccessat */
	439,	/* faccessat2 */
	223,	/* fadvise64 */
	47,	/* fallocate */
	262,	/* fanotify_init */
	263,	/* fanotify_mark */
	50,	/* fchdir */
	52,	/* fchmod */
	53,	/* fchmodat */
	452,	/* fchmodat2 */
	55,	/* fchown */
	54,	/* fchownat */
	25,	/* fcntl */
	83,	/* fdatasync */
	10,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	273,	/* finit_module */
	13,	/* flistxattr */
	32,	/* flock */
	16,	/* fremovexattr */
	431,	/* fsconfig */
	7,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	80,	/* fstat */
	44,	/* fstatfs */
	82,	/* fsync */
	46,	/* ftruncate */
	98,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	236,	/* get_mempolicy */
	100,	/* get_robust_list */
	168,	/* getcpu */
	17,	/* getcwd */
	61,	/* getdents64 */
	177,	/* getegid */
	175,	/* geteuid */
	176,	/* getgid */
	158,	/* getgroups */
	102,	/* getitimer */
	205,	/* getpeername */
	155,	/* getpgid */
	172,	/* getpid */
	173,	/* getppid */
	141,	/* getpriority */
	278,	/* getrandom */
	150,	/* getresgid */
	148,	/* getresuid */
	163,	/* getrlimit */
	165,	/* getrusage */
	156,	/* getsid */
	204,	/* getsockname */
	209,	/* getsockopt */
	178,	/* gettid */
	169,	/* gettimeofday */
	174,	/* getuid */
	8,	/* getxattr */
	464,	/* getxattrat */
	105,	/* init_module */
	27,	/* inotify_add_watch */
	26,	/* inotify_init1 */
	28,	/* inotify_rm_watch */
	3,	/* io_cancel */
	1,	/* io_destroy */
	4,	/* io_getevents */
	292,	/* io_pgetevents */
	0,	/* io_setup */
	2,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	29,	/* ioctl */
	31,	/* ioprio_get */
	30,	/* ioprio_set */
	272,	/* kcmp */
	294,	/* kexec_file_load */
	104,	/* kexec_load */
	219,	/* keyctl */
	129,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	9,	/* lgetxattr */
	37,	/* linkat */
	201,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	11,	/* listxattr */
	465,	/* listxattrat */
	12,	/* llistxattr */
	18,	/* lookup_dcookie */
	15,	/* lremovexattr */
	62,	/* lseek */
	6,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	233,	/* madvise */
	453,	/* map_shadow_stack */
	235,	/* mbind */
	283,	/* membarrier */
	279,	/* memfd_create */
	447,	/* memfd_secret */
	238,	/* migrate_pages */
	232,	/* mincore */
	34,	/* mkdirat */
	33,	/* mknodat */
	228,	/* mlock */
	284,	/* mlock2 */
	230,	/* mlockall */
	222,	/* mmap */
	40,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	239,	/* move_pages */
	226,	/* mprotect */
	185,	/* mq_getsetattr */
	184,	/* mq_notify */
	180,	/* mq_open */
	183,	/* mq_timedreceive */
	182,	/* mq_timedsend */
	181,	/* mq_unlink */
	216,	/* mremap */
	462,	/* mseal */
	187,	/* msgctl */
	186,	/* msgget */
	188,	/* msgrcv */
	189,	/* msgsnd */
	227,	/* msync */
	229,	/* munlock */
	231,	/* munlockall */
	215,	/* munmap */
	264,	/* name_to_handle_at */
	101,	/* nanosleep */
	79,	/* newfstatat */
	42,	/* nfsservctl */
	265,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	56,	/* openat */
	437,	/* openat2 */
	241,	/* perf_event_open */
	92,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	59,	/* pipe2 */
	41,	/* pivot_root */
	289,	/* pkey_alloc */
	290,	/* pkey_free */
	288,	/* pkey_mprotect */
	73,	/* ppoll */
	167,	/* prctl */
	67,	/* pread64 */
	69,	/* preadv */
	286,	/* preadv2 */
	261,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	270,	/* process_vm_readv */
	271,	/* process_vm_writev */
	72,	/* pselect6 */
	117,	/* ptrace */
	68,	/* pwrite64 */
	70,	/* pwritev */
	287,	/* pwritev2 */
	60,	/* quotactl */
	443,	/* quotactl_fd */
	63,	/* read */
	213,	/* readahead */
	78,	/* readlinkat */
	65,	/* readv */
	142,	/* reboot */
	207,	/* recvfrom */
	243,	/* recvmmsg */
	212,	/* recvmsg */
	234,	/* remap_file_pages */
	14,	/* removexattr */
	466,	/* removexattrat */
	38,	/* renameat */
	276,	/* renameat2 */
	218,	/* request_key */
	128,	/* restart_syscall */
	293,	/* rseq */
	471,	/* rseq_slice_yield */
	134,	/* rt_sigaction */
	136,	/* rt_sigpending */
	135,	/* rt_sigprocmask */
	138,	/* rt_sigqueueinfo */
	139,	/* rt_sigreturn */
	133,	/* rt_sigsuspend */
	137,	/* rt_sigtimedwait */
	240,	/* rt_tgsigqueueinfo */
	125,	/* sched_get_priority_max */
	126,	/* sched_get_priority_min */
	123,	/* sched_getaffinity */
	275,	/* sched_getattr */
	121,	/* sched_getparam */
	120,	/* sched_getscheduler */
	127,	/* sched_rr_get_interval */
	122,	/* sched_setaffinity */
	274,	/* sched_setattr */
	118,	/* sched_setparam */
	119,	/* sched_setscheduler */
	124,	/* sched_yield */
	277,	/* seccomp */
	191,	/* semctl */
	190,	/* semget */
	193,	/* semop */
	192,	/* semtimedop */
	71,	/* sendfile */
	269,	/* sendmmsg */
	211,	/* sendmsg */
	206,	/* sendto */
	237,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	99,	/* set_robust_list */
	96,	/* set_tid_address */
	162,	/* setdomainname */
	152,	/* setfsgid */
	151,	/* setfsuid */
	144,	/* setgid */
	159,	/* setgroups */
	161,	/* sethostname */
	103,	/* setitimer */
	268,	/* setns */
	154,	/* setpgid */
	140,	/* setpriority */
	143,	/* setregid */
	149,	/* setresgid */
	147,	/* setresuid */
	145,	/* setreuid */
	164,	/* setrlimit */
	157,	/* setsid */
	208,	/* setsockopt */
	170,	/* settimeofday */
	146,	/* setuid */
	5,	/* setxattr */
	463,	/* setxattrat */
	196,	/* shmat */
	195,	/* shmctl */
	197,	/* shmdt */
	194,	/* shmget */
	210,	/* shutdown */
	132,	/* sigaltstack */
	74,	/* signalfd4 */
	198,	/* socket */
	199,	/* socketpair */
	76,	/* splice */
	43,	/* statfs */
	457,	/* statmount */
	291,	/* statx */
	225,	/* swapoff */
	224,	/* swapon */
	36,	/* symlinkat */
	81,	/* sync */
	84,	/* sync_file_range */
	267,	/* syncfs */
	179,	/* sysinfo */
	116,	/* syslog */
	77,	/* tee */
	131,	/* tgkill */
	107,	/* timer_create */
	111,	/* timer_delete */
	109,	/* timer_getoverrun */
	108,	/* timer_gettime */
	110,	/* timer_settime */
	85,	/* timerfd_create */
	87,	/* timerfd_gettime */
	86,	/* timerfd_settime */
	153,	/* times */
	130,	/* tkill */
	45,	/* truncate */
	166,	/* umask */
	39,	/* umount2 */
	160,	/* uname */
	35,	/* unlinkat */
	97,	/* unshare */
	282,	/* userfaultfd */
	88,	/* utimensat */
	58,	/* vhangup */
	75,	/* vmsplice */
	260,	/* wait4 */
	95,	/* waitid */
	64,	/* write */
	66,	/* writev */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__arm__) || defined(__aarch64__)

#if defined(ALL_SYSCALLTBL) || defined(__csky__)
static const char *const syscall_num_to_name_EM_CSKY[] = {
	[0] = "io_setup",
	[1] = "io_destroy",
	[2] = "io_submit",
	[3] = "io_cancel",
	[4] = "io_getevents",
	[5] = "setxattr",
	[6] = "lsetxattr",
	[7] = "fsetxattr",
	[8] = "getxattr",
	[9] = "lgetxattr",
	[10] = "fgetxattr",
	[11] = "listxattr",
	[12] = "llistxattr",
	[13] = "flistxattr",
	[14] = "removexattr",
	[15] = "lremovexattr",
	[16] = "fremovexattr",
	[17] = "getcwd",
	[18] = "lookup_dcookie",
	[19] = "eventfd2",
	[20] = "epoll_create1",
	[21] = "epoll_ctl",
	[22] = "epoll_pwait",
	[23] = "dup",
	[24] = "dup3",
	[25] = "fcntl64",
	[26] = "inotify_init1",
	[27] = "inotify_add_watch",
	[28] = "inotify_rm_watch",
	[29] = "ioctl",
	[30] = "ioprio_set",
	[31] = "ioprio_get",
	[32] = "flock",
	[33] = "mknodat",
	[34] = "mkdirat",
	[35] = "unlinkat",
	[36] = "symlinkat",
	[37] = "linkat",
	[39] = "umount2",
	[40] = "mount",
	[41] = "pivot_root",
	[42] = "nfsservctl",
	[43] = "statfs64",
	[44] = "fstatfs64",
	[45] = "truncate64",
	[46] = "ftruncate64",
	[47] = "fallocate",
	[48] = "faccessat",
	[49] = "chdir",
	[50] = "fchdir",
	[51] = "chroot",
	[52] = "fchmod",
	[53] = "fchmodat",
	[54] = "fchownat",
	[55] = "fchown",
	[56] = "openat",
	[57] = "close",
	[58] = "vhangup",
	[59] = "pipe2",
	[60] = "quotactl",
	[61] = "getdents64",
	[62] = "llseek",
	[63] = "read",
	[64] = "write",
	[65] = "readv",
	[66] = "writev",
	[67] = "pread64",
	[68] = "pwrite64",
	[69] = "preadv",
	[70] = "pwritev",
	[71] = "sendfile64",
	[72] = "pselect6",
	[73] = "ppoll",
	[74] = "signalfd4",
	[75] = "vmsplice",
	[76] = "splice",
	[77] = "tee",
	[78] = "readlinkat",
	[79] = "fstatat64",
	[80] = "fstat64",
	[81] = "sync",
	[82] = "fsync",
	[83] = "fdatasync",
	[84] = "sync_file_range",
	[85] = "timerfd_create",
	[86] = "timerfd_settime",
	[87] = "timerfd_gettime",
	[88] = "utimensat",
	[89] = "acct",
	[90] = "capget",
	[91] = "capset",
	[92] = "personality",
	[93] = "exit",
	[94] = "exit_group",
	[95] = "waitid",
	[96] = "set_tid_address",
	[97] = "unshare",
	[98] = "futex",
	[99] = "set_robust_list",
	[100] = "get_robust_list",
	[101] = "nanosleep",
	[102] = "getitimer",
	[103] = "setitimer",
	[104] = "kexec_load",
	[105] = "init_module",
	[106] = "delete_module",
	[107] = "timer_create",
	[108] = "timer_gettime",
	[109] = "timer_getoverrun",
	[110] = "timer_settime",
	[111] = "timer_delete",
	[112] = "clock_settime",
	[113] = "clock_gettime",
	[114] = "clock_getres",
	[115] = "clock_nanosleep",
	[116] = "syslog",
	[117] = "ptrace",
	[118] = "sched_setparam",
	[119] = "sched_setscheduler",
	[120] = "sched_getscheduler",
	[121] = "sched_getparam",
	[122] = "sched_setaffinity",
	[123] = "sched_getaffinity",
	[124] = "sched_yield",
	[125] = "sched_get_priority_max",
	[126] = "sched_get_priority_min",
	[127] = "sched_rr_get_interval",
	[128] = "restart_syscall",
	[129] = "kill",
	[130] = "tkill",
	[131] = "tgkill",
	[132] = "sigaltstack",
	[133] = "rt_sigsuspend",
	[134] = "rt_sigaction",
	[135] = "rt_sigprocmask",
	[136] = "rt_sigpending",
	[137] = "rt_sigtimedwait",
	[138] = "rt_sigqueueinfo",
	[139] = "rt_sigreturn",
	[140] = "setpriority",
	[141] = "getpriority",
	[142] = "reboot",
	[143] = "setregid",
	[144] = "setgid",
	[145] = "setreuid",
	[146] = "setuid",
	[147] = "setresuid",
	[148] = "getresuid",
	[149] = "setresgid",
	[150] = "getresgid",
	[151] = "setfsuid",
	[152] = "setfsgid",
	[153] = "times",
	[154] = "setpgid",
	[155] = "getpgid",
	[156] = "getsid",
	[157] = "setsid",
	[158] = "getgroups",
	[159] = "setgroups",
	[160] = "uname",
	[161] = "sethostname",
	[162] = "setdomainname",
	[163] = "getrlimit",
	[164] = "setrlimit",
	[165] = "getrusage",
	[166] = "umask",
	[167] = "prctl",
	[168] = "getcpu",
	[169] = "gettimeofday",
	[170] = "settimeofday",
	[171] = "adjtimex",
	[172] = "getpid",
	[173] = "getppid",
	[174] = "getuid",
	[175] = "geteuid",
	[176] = "getgid",
	[177] = "getegid",
	[178] = "gettid",
	[179] = "sysinfo",
	[180] = "mq_open",
	[181] = "mq_unlink",
	[182] = "mq_timedsend",
	[183] = "mq_timedreceive",
	[184] = "mq_notify",
	[185] = "mq_getsetattr",
	[186] = "msgget",
	[187] = "msgctl",
	[188] = "msgrcv",
	[189] = "msgsnd",
	[190] = "semget",
	[191] = "semctl",
	[192] = "semtimedop",
	[193] = "semop",
	[194] = "shmget",
	[195] = "shmctl",
	[196] = "shmat",
	[197] = "shmdt",
	[198] = "socket",
	[199] = "socketpair",
	[200] = "bind",
	[201] = "listen",
	[202] = "accept",
	[203] = "connect",
	[204] = "getsockname",
	[205] = "getpeername",
	[206] = "sendto",
	[207] = "recvfrom",
	[208] = "setsockopt",
	[209] = "getsockopt",
	[210] = "shutdown",
	[211] = "sendmsg",
	[212] = "recvmsg",
	[213] = "readahead",
	[214] = "brk",
	[215] = "munmap",
	[216] = "mremap",
	[217] = "add_key",
	[218] = "request_key",
	[219] = "keyctl",
	[220] = "clone",
	[221] = "execve",
	[222] = "mmap2",
	[223] = "fadvise64_64",
	[224] = "swapon",
	[225] = "swapoff",
	[226] = "mprotect",
	[227] = "msync",
	[228] = "mlock",
	[229] = "munlock",
	[230] = "mlockall",
	[231] = "munlockall",
	[232] = "mincore",
	[233] = "madvise",
	[234] = "remap_file_pages",
	[235] = "mbind",
	[236] = "get_mempolicy",
	[237] = "set_mempolicy",
	[238] = "migrate_pages",
	[239] = "move_pages",
	[240] = "rt_tgsigqueueinfo",
	[241] = "perf_event_open",
	[242] = "accept4",
	[243] = "recvmmsg",
	[244] = "set_thread_area",
	[245] = "cacheflush",
	[260] = "wait4",
	[261] = "prlimit64",
	[262] = "fanotify_init",
	[263] = "fanotify_mark",
	[264] = "name_to_handle_at",
	[265] = "open_by_handle_at",
	[266] = "clock_adjtime",
	[267] = "syncfs",
	[268] = "setns",
	[269] = "sendmmsg",
	[270] = "process_vm_readv",
	[271] = "process_vm_writev",
	[272] = "kcmp",
	[273] = "finit_module",
	[274] = "sched_setattr",
	[275] = "sched_getattr",
	[276] = "renameat2",
	[277] = "seccomp",
	[278] = "getrandom",
	[279] = "memfd_create",
	[280] = "bpf",
	[281] = "execveat",
	[282] = "userfaultfd",
	[283] = "membarrier",
	[284] = "mlock2",
	[285] = "copy_file_range",
	[286] = "preadv2",
	[287] = "pwritev2",
	[288] = "pkey_mprotect",
	[289] = "pkey_alloc",
	[290] = "pkey_free",
	[291] = "statx",
	[292] = "io_pgetevents",
	[293] = "rseq",
	[294] = "kexec_file_load",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_CSKY[] = {
	202,	/* accept */
	242,	/* accept4 */
	89,	/* acct */
	217,	/* add_key */
	171,	/* adjtimex */
	200,	/* bind */
	280,	/* bpf */
	214,	/* brk */
	245,	/* cacheflush */
	451,	/* cachestat */
	90,	/* capget */
	91,	/* capset */
	49,	/* chdir */
	51,	/* chroot */
	266,	/* clock_adjtime */
	405,	/* clock_adjtime64 */
	114,	/* clock_getres */
	406,	/* clock_getres_time64 */
	113,	/* clock_gettime */
	403,	/* clock_gettime64 */
	115,	/* clock_nanosleep */
	407,	/* clock_nanosleep_time64 */
	112,	/* clock_settime */
	404,	/* clock_settime64 */
	220,	/* clone */
	435,	/* clone3 */
	57,	/* close */
	436,	/* close_range */
	203,	/* connect */
	285,	/* copy_file_range */
	106,	/* delete_module */
	23,	/* dup */
	24,	/* dup3 */
	20,	/* epoll_create1 */
	21,	/* epoll_ctl */
	22,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	19,	/* eventfd2 */
	221,	/* execve */
	281,	/* execveat */
	93,	/* exit */
	94,	/* exit_group */
	48,	/* faccessat */
	439,	/* faccessat2 */
	223,	/* fadvise64_64 */
	47,	/* fallocate */
	262,	/* fanotify_init */
	263,	/* fanotify_mark */
	50,	/* fchdir */
	52,	/* fchmod */
	53,	/* fchmodat */
	452,	/* fchmodat2 */
	55,	/* fchown */
	54,	/* fchownat */
	25,	/* fcntl64 */
	83,	/* fdatasync */
	10,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	273,	/* finit_module */
	13,	/* flistxattr */
	32,	/* flock */
	16,	/* fremovexattr */
	431,	/* fsconfig */
	7,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	80,	/* fstat64 */
	79,	/* fstatat64 */
	44,	/* fstatfs64 */
	82,	/* fsync */
	46,	/* ftruncate64 */
	98,	/* futex */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	236,	/* get_mempolicy */
	100,	/* get_robust_list */
	168,	/* getcpu */
	17,	/* getcwd */
	61,	/* getdents64 */
	177,	/* getegid */
	175,	/* geteuid */
	176,	/* getgid */
	158,	/* getgroups */
	102,	/* getitimer */
	205,	/* getpeername */
	155,	/* getpgid */
	172,	/* getpid */
	173,	/* getppid */
	141,	/* getpriority */
	278,	/* getrandom */
	150,	/* getresgid */
	148,	/* getresuid */
	163,	/* getrlimit */
	165,	/* getrusage */
	156,	/* getsid */
	204,	/* getsockname */
	209,	/* getsockopt */
	178,	/* gettid */
	169,	/* gettimeofday */
	174,	/* getuid */
	8,	/* getxattr */
	464,	/* getxattrat */
	105,	/* init_module */
	27,	/* inotify_add_watch */
	26,	/* inotify_init1 */
	28,	/* inotify_rm_watch */
	3,	/* io_cancel */
	1,	/* io_destroy */
	4,	/* io_getevents */
	292,	/* io_pgetevents */
	416,	/* io_pgetevents_time64 */
	0,	/* io_setup */
	2,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	29,	/* ioctl */
	31,	/* ioprio_get */
	30,	/* ioprio_set */
	272,	/* kcmp */
	294,	/* kexec_file_load */
	104,	/* kexec_load */
	219,	/* keyctl */
	129,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	9,	/* lgetxattr */
	37,	/* linkat */
	201,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	11,	/* listxattr */
	465,	/* listxattrat */
	12,	/* llistxattr */
	62,	/* llseek */
	18,	/* lookup_dcookie */
	15,	/* lremovexattr */
	6,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	233,	/* madvise */
	453,	/* map_shadow_stack */
	235,	/* mbind */
	283,	/* membarrier */
	279,	/* memfd_create */
	238,	/* migrate_pages */
	232,	/* mincore */
	34,	/* mkdirat */
	33,	/* mknodat */
	228,	/* mlock */
	284,	/* mlock2 */
	230,	/* mlockall */
	222,	/* mmap2 */
	40,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	239,	/* move_pages */
	226,	/* mprotect */
	185,	/* mq_getsetattr */
	184,	/* mq_notify */
	180,	/* mq_open */
	183,	/* mq_timedreceive */
	419,	/* mq_timedreceive_time64 */
	182,	/* mq_timedsend */
	418,	/* mq_timedsend_time64 */
	181,	/* mq_unlink */
	216,	/* mremap */
	462,	/* mseal */
	187,	/* msgctl */
	186,	/* msgget */
	188,	/* msgrcv */
	189,	/* msgsnd */
	227,	/* msync */
	229,	/* munlock */
	231,	/* munlockall */
	215,	/* munmap */
	264,	/* name_to_handle_at */
	101,	/* nanosleep */
	42,	/* nfsservctl */
	265,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	56,	/* openat */
	437,	/* openat2 */
	241,	/* perf_event_open */
	92,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	59,	/* pipe2 */
	41,	/* pivot_root */
	289,	/* pkey_alloc */
	290,	/* pkey_free */
	288,	/* pkey_mprotect */
	73,	/* ppoll */
	414,	/* ppoll_time64 */
	167,	/* prctl */
	67,	/* pread64 */
	69,	/* preadv */
	286,	/* preadv2 */
	261,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	270,	/* process_vm_readv */
	271,	/* process_vm_writev */
	72,	/* pselect6 */
	413,	/* pselect6_time64 */
	117,	/* ptrace */
	68,	/* pwrite64 */
	70,	/* pwritev */
	287,	/* pwritev2 */
	60,	/* quotactl */
	443,	/* quotactl_fd */
	63,	/* read */
	213,	/* readahead */
	78,	/* readlinkat */
	65,	/* readv */
	142,	/* reboot */
	207,	/* recvfrom */
	243,	/* recvmmsg */
	417,	/* recvmmsg_time64 */
	212,	/* recvmsg */
	234,	/* remap_file_pages */
	14,	/* removexattr */
	466,	/* removexattrat */
	276,	/* renameat2 */
	218,	/* request_key */
	128,	/* restart_syscall */
	293,	/* rseq */
	471,	/* rseq_slice_yield */
	134,	/* rt_sigaction */
	136,	/* rt_sigpending */
	135,	/* rt_sigprocmask */
	138,	/* rt_sigqueueinfo */
	139,	/* rt_sigreturn */
	133,	/* rt_sigsuspend */
	137,	/* rt_sigtimedwait */
	421,	/* rt_sigtimedwait_time64 */
	240,	/* rt_tgsigqueueinfo */
	125,	/* sched_get_priority_max */
	126,	/* sched_get_priority_min */
	123,	/* sched_getaffinity */
	275,	/* sched_getattr */
	121,	/* sched_getparam */
	120,	/* sched_getscheduler */
	127,	/* sched_rr_get_interval */
	423,	/* sched_rr_get_interval_time64 */
	122,	/* sched_setaffinity */
	274,	/* sched_setattr */
	118,	/* sched_setparam */
	119,	/* sched_setscheduler */
	124,	/* sched_yield */
	277,	/* seccomp */
	191,	/* semctl */
	190,	/* semget */
	193,	/* semop */
	192,	/* semtimedop */
	420,	/* semtimedop_time64 */
	71,	/* sendfile64 */
	269,	/* sendmmsg */
	211,	/* sendmsg */
	206,	/* sendto */
	237,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	99,	/* set_robust_list */
	244,	/* set_thread_area */
	96,	/* set_tid_address */
	162,	/* setdomainname */
	152,	/* setfsgid */
	151,	/* setfsuid */
	144,	/* setgid */
	159,	/* setgroups */
	161,	/* sethostname */
	103,	/* setitimer */
	268,	/* setns */
	154,	/* setpgid */
	140,	/* setpriority */
	143,	/* setregid */
	149,	/* setresgid */
	147,	/* setresuid */
	145,	/* setreuid */
	164,	/* setrlimit */
	157,	/* setsid */
	208,	/* setsockopt */
	170,	/* settimeofday */
	146,	/* setuid */
	5,	/* setxattr */
	463,	/* setxattrat */
	196,	/* shmat */
	195,	/* shmctl */
	197,	/* shmdt */
	194,	/* shmget */
	210,	/* shutdown */
	132,	/* sigaltstack */
	74,	/* signalfd4 */
	198,	/* socket */
	199,	/* socketpair */
	76,	/* splice */
	43,	/* statfs64 */
	457,	/* statmount */
	291,	/* statx */
	225,	/* swapoff */
	224,	/* swapon */
	36,	/* symlinkat */
	81,	/* sync */
	84,	/* sync_file_range */
	267,	/* syncfs */
	179,	/* sysinfo */
	116,	/* syslog */
	77,	/* tee */
	131,	/* tgkill */
	107,	/* timer_create */
	111,	/* timer_delete */
	109,	/* timer_getoverrun */
	108,	/* timer_gettime */
	408,	/* timer_gettime64 */
	110,	/* timer_settime */
	409,	/* timer_settime64 */
	85,	/* timerfd_create */
	87,	/* timerfd_gettime */
	410,	/* timerfd_gettime64 */
	86,	/* timerfd_settime */
	411,	/* timerfd_settime64 */
	153,	/* times */
	130,	/* tkill */
	45,	/* truncate64 */
	166,	/* umask */
	39,	/* umount2 */
	160,	/* uname */
	35,	/* unlinkat */
	97,	/* unshare */
	282,	/* userfaultfd */
	88,	/* utimensat */
	412,	/* utimensat_time64 */
	58,	/* vhangup */
	75,	/* vmsplice */
	260,	/* wait4 */
	95,	/* waitid */
	64,	/* write */
	66,	/* writev */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__csky__)

#if defined(ALL_SYSCALLTBL) || defined(__mips__)
static const char *const syscall_num_to_name_EM_MIPS[] = {
	[0] = "read",
	[1] = "write",
	[2] = "open",
	[3] = "close",
	[4] = "stat",
	[5] = "fstat",
	[6] = "lstat",
	[7] = "poll",
	[8] = "lseek",
	[9] = "mmap",
	[10] = "mprotect",
	[11] = "munmap",
	[12] = "brk",
	[13] = "rt_sigaction",
	[14] = "rt_sigprocmask",
	[15] = "ioctl",
	[16] = "pread64",
	[17] = "pwrite64",
	[18] = "readv",
	[19] = "writev",
	[20] = "access",
	[21] = "pipe",
	[22] = "_newselect",
	[23] = "sched_yield",
	[24] = "mremap",
	[25] = "msync",
	[26] = "mincore",
	[27] = "madvise",
	[28] = "shmget",
	[29] = "shmat",
	[30] = "shmctl",
	[31] = "dup",
	[32] = "dup2",
	[33] = "pause",
	[34] = "nanosleep",
	[35] = "getitimer",
	[36] = "setitimer",
	[37] = "alarm",
	[38] = "getpid",
	[39] = "sendfile",
	[40] = "socket",
	[41] = "connect",
	[42] = "accept",
	[43] = "sendto",
	[44] = "recvfrom",
	[45] = "sendmsg",
	[46] = "recvmsg",
	[47] = "shutdown",
	[48] = "bind",
	[49] = "listen",
	[50] = "getsockname",
	[51] = "getpeername",
	[52] = "socketpair",
	[53] = "setsockopt",
	[54] = "getsockopt",
	[55] = "clone",
	[56] = "fork",
	[57] = "execve",
	[58] = "exit",
	[59] = "wait4",
	[60] = "kill",
	[61] = "uname",
	[62] = "semget",
	[63] = "semop",
	[64] = "semctl",
	[65] = "shmdt",
	[66] = "msgget",
	[67] = "msgsnd",
	[68] = "msgrcv",
	[69] = "msgctl",
	[70] = "fcntl",
	[71] = "flock",
	[72] = "fsync",
	[73] = "fdatasync",
	[74] = "truncate",
	[75] = "ftruncate",
	[76] = "getdents",
	[77] = "getcwd",
	[78] = "chdir",
	[79] = "fchdir",
	[80] = "rename",
	[81] = "mkdir",
	[82] = "rmdir",
	[83] = "creat",
	[84] = "link",
	[85] = "unlink",
	[86] = "symlink",
	[87] = "readlink",
	[88] = "chmod",
	[89] = "fchmod",
	[90] = "chown",
	[91] = "fchown",
	[92] = "lchown",
	[93] = "umask",
	[94] = "gettimeofday",
	[95] = "getrlimit",
	[96] = "getrusage",
	[97] = "sysinfo",
	[98] = "times",
	[99] = "ptrace",
	[100] = "getuid",
	[101] = "syslog",
	[102] = "getgid",
	[103] = "setuid",
	[104] = "setgid",
	[105] = "geteuid",
	[106] = "getegid",
	[107] = "setpgid",
	[108] = "getppid",
	[109] = "getpgrp",
	[110] = "setsid",
	[111] = "setreuid",
	[112] = "setregid",
	[113] = "getgroups",
	[114] = "setgroups",
	[115] = "setresuid",
	[116] = "getresuid",
	[117] = "setresgid",
	[118] = "getresgid",
	[119] = "getpgid",
	[120] = "setfsuid",
	[121] = "setfsgid",
	[122] = "getsid",
	[123] = "capget",
	[124] = "capset",
	[125] = "rt_sigpending",
	[126] = "rt_sigtimedwait",
	[127] = "rt_sigqueueinfo",
	[128] = "rt_sigsuspend",
	[129] = "sigaltstack",
	[130] = "utime",
	[131] = "mknod",
	[132] = "personality",
	[133] = "ustat",
	[134] = "statfs",
	[135] = "fstatfs",
	[136] = "sysfs",
	[137] = "getpriority",
	[138] = "setpriority",
	[139] = "sched_setparam",
	[140] = "sched_getparam",
	[141] = "sched_setscheduler",
	[142] = "sched_getscheduler",
	[143] = "sched_get_priority_max",
	[144] = "sched_get_priority_min",
	[145] = "sched_rr_get_interval",
	[146] = "mlock",
	[147] = "munlock",
	[148] = "mlockall",
	[149] = "munlockall",
	[150] = "vhangup",
	[151] = "pivot_root",
	[152] = "_sysctl",
	[153] = "prctl",
	[154] = "adjtimex",
	[155] = "setrlimit",
	[156] = "chroot",
	[157] = "sync",
	[158] = "acct",
	[159] = "settimeofday",
	[160] = "mount",
	[161] = "umount2",
	[162] = "swapon",
	[163] = "swapoff",
	[164] = "reboot",
	[165] = "sethostname",
	[166] = "setdomainname",
	[167] = "create_module",
	[168] = "init_module",
	[169] = "delete_module",
	[170] = "get_kernel_syms",
	[171] = "query_module",
	[172] = "quotactl",
	[173] = "nfsservctl",
	[174] = "getpmsg",
	[175] = "putpmsg",
	[176] = "afs_syscall",
	[177] = "reserved177",
	[178] = "gettid",
	[179] = "readahead",
	[180] = "setxattr",
	[181] = "lsetxattr",
	[182] = "fsetxattr",
	[183] = "getxattr",
	[184] = "lgetxattr",
	[185] = "fgetxattr",
	[186] = "listxattr",
	[187] = "llistxattr",
	[188] = "flistxattr",
	[189] = "removexattr",
	[190] = "lremovexattr",
	[191] = "fremovexattr",
	[192] = "tkill",
	[193] = "reserved193",
	[194] = "futex",
	[195] = "sched_setaffinity",
	[196] = "sched_getaffinity",
	[197] = "cacheflush",
	[198] = "cachectl",
	[199] = "sysmips",
	[200] = "io_setup",
	[201] = "io_destroy",
	[202] = "io_getevents",
	[203] = "io_submit",
	[204] = "io_cancel",
	[205] = "exit_group",
	[206] = "lookup_dcookie",
	[207] = "epoll_create",
	[208] = "epoll_ctl",
	[209] = "epoll_wait",
	[210] = "remap_file_pages",
	[211] = "rt_sigreturn",
	[212] = "set_tid_address",
	[213] = "restart_syscall",
	[214] = "semtimedop",
	[215] = "fadvise64",
	[216] = "timer_create",
	[217] = "timer_settime",
	[218] = "timer_gettime",
	[219] = "timer_getoverrun",
	[220] = "timer_delete",
	[221] = "clock_settime",
	[222] = "clock_gettime",
	[223] = "clock_getres",
	[224] = "clock_nanosleep",
	[225] = "tgkill",
	[226] = "utimes",
	[227] = "mbind",
	[228] = "get_mempolicy",
	[229] = "set_mempolicy",
	[230] = "mq_open",
	[231] = "mq_unlink",
	[232] = "mq_timedsend",
	[233] = "mq_timedreceive",
	[234] = "mq_notify",
	[235] = "mq_getsetattr",
	[236] = "vserver",
	[237] = "waitid",
	[239] = "add_key",
	[240] = "request_key",
	[241] = "keyctl",
	[242] = "set_thread_area",
	[243] = "inotify_init",
	[244] = "inotify_add_watch",
	[245] = "inotify_rm_watch",
	[246] = "migrate_pages",
	[247] = "openat",
	[248] = "mkdirat",
	[249] = "mknodat",
	[250] = "fchownat",
	[251] = "futimesat",
	[252] = "newfstatat",
	[253] = "unlinkat",
	[254] = "renameat",
	[255] = "linkat",
	[256] = "symlinkat",
	[257] = "readlinkat",
	[258] = "fchmodat",
	[259] = "faccessat",
	[260] = "pselect6",
	[261] = "ppoll",
	[262] = "unshare",
	[263] = "splice",
	[264] = "sync_file_range",
	[265] = "tee",
	[266] = "vmsplice",
	[267] = "move_pages",
	[268] = "set_robust_list",
	[269] = "get_robust_list",
	[270] = "kexec_load",
	[271] = "getcpu",
	[272] = "epoll_pwait",
	[273] = "ioprio_set",
	[274] = "ioprio_get",
	[275] = "utimensat",
	[276] = "signalfd",
	[277] = "timerfd",
	[278] = "eventfd",
	[279] = "fallocate",
	[280] = "timerfd_create",
	[281] = "timerfd_gettime",
	[282] = "timerfd_settime",
	[283] = "signalfd4",
	[284] = "eventfd2",
	[285] = "epoll_create1",
	[286] = "dup3",
	[287] = "pipe2",
	[288] = "inotify_init1",
	[289] = "preadv",
	[290] = "pwritev",
	[291] = "rt_tgsigqueueinfo",
	[292] = "perf_event_open",
	[293] = "accept4",
	[294] = "recvmmsg",
	[295] = "fanotify_init",
	[296] = "fanotify_mark",
	[297] = "prlimit64",
	[298] = "name_to_handle_at",
	[299] = "open_by_handle_at",
	[300] = "clock_adjtime",
	[301] = "syncfs",
	[302] = "sendmmsg",
	[303] = "setns",
	[304] = "process_vm_readv",
	[305] = "process_vm_writev",
	[306] = "kcmp",
	[307] = "finit_module",
	[308] = "getdents64",
	[309] = "sched_setattr",
	[310] = "sched_getattr",
	[311] = "renameat2",
	[312] = "seccomp",
	[313] = "getrandom",
	[314] = "memfd_create",
	[315] = "bpf",
	[316] = "execveat",
	[317] = "userfaultfd",
	[318] = "membarrier",
	[319] = "mlock2",
	[320] = "copy_file_range",
	[321] = "preadv2",
	[322] = "pwritev2",
	[323] = "pkey_mprotect",
	[324] = "pkey_alloc",
	[325] = "pkey_free",
	[326] = "statx",
	[327] = "rseq",
	[328] = "io_pgetevents",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_MIPS[] = {
	22,	/* _newselect */
	152,	/* _sysctl */
	42,	/* accept */
	293,	/* accept4 */
	20,	/* access */
	158,	/* acct */
	239,	/* add_key */
	154,	/* adjtimex */
	176,	/* afs_syscall */
	37,	/* alarm */
	48,	/* bind */
	315,	/* bpf */
	12,	/* brk */
	198,	/* cachectl */
	197,	/* cacheflush */
	451,	/* cachestat */
	123,	/* capget */
	124,	/* capset */
	78,	/* chdir */
	88,	/* chmod */
	90,	/* chown */
	156,	/* chroot */
	300,	/* clock_adjtime */
	223,	/* clock_getres */
	222,	/* clock_gettime */
	224,	/* clock_nanosleep */
	221,	/* clock_settime */
	55,	/* clone */
	435,	/* clone3 */
	3,	/* close */
	436,	/* close_range */
	41,	/* connect */
	320,	/* copy_file_range */
	83,	/* creat */
	167,	/* create_module */
	169,	/* delete_module */
	31,	/* dup */
	32,	/* dup2 */
	286,	/* dup3 */
	207,	/* epoll_create */
	285,	/* epoll_create1 */
	208,	/* epoll_ctl */
	272,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	209,	/* epoll_wait */
	278,	/* eventfd */
	284,	/* eventfd2 */
	57,	/* execve */
	316,	/* execveat */
	58,	/* exit */
	205,	/* exit_group */
	259,	/* faccessat */
	439,	/* faccessat2 */
	215,	/* fadvise64 */
	279,	/* fallocate */
	295,	/* fanotify_init */
	296,	/* fanotify_mark */
	79,	/* fchdir */
	89,	/* fchmod */
	258,	/* fchmodat */
	452,	/* fchmodat2 */
	91,	/* fchown */
	250,	/* fchownat */
	70,	/* fcntl */
	73,	/* fdatasync */
	185,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	307,	/* finit_module */
	188,	/* flistxattr */
	71,	/* flock */
	56,	/* fork */
	191,	/* fremovexattr */
	431,	/* fsconfig */
	182,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	5,	/* fstat */
	135,	/* fstatfs */
	72,	/* fsync */
	75,	/* ftruncate */
	194,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	251,	/* futimesat */
	170,	/* get_kernel_syms */
	228,	/* get_mempolicy */
	269,	/* get_robust_list */
	271,	/* getcpu */
	77,	/* getcwd */
	76,	/* getdents */
	308,	/* getdents64 */
	106,	/* getegid */
	105,	/* geteuid */
	102,	/* getgid */
	113,	/* getgroups */
	35,	/* getitimer */
	51,	/* getpeername */
	119,	/* getpgid */
	109,	/* getpgrp */
	38,	/* getpid */
	174,	/* getpmsg */
	108,	/* getppid */
	137,	/* getpriority */
	313,	/* getrandom */
	118,	/* getresgid */
	116,	/* getresuid */
	95,	/* getrlimit */
	96,	/* getrusage */
	122,	/* getsid */
	50,	/* getsockname */
	54,	/* getsockopt */
	178,	/* gettid */
	94,	/* gettimeofday */
	100,	/* getuid */
	183,	/* getxattr */
	464,	/* getxattrat */
	168,	/* init_module */
	244,	/* inotify_add_watch */
	243,	/* inotify_init */
	288,	/* inotify_init1 */
	245,	/* inotify_rm_watch */
	204,	/* io_cancel */
	201,	/* io_destroy */
	202,	/* io_getevents */
	328,	/* io_pgetevents */
	200,	/* io_setup */
	203,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	15,	/* ioctl */
	274,	/* ioprio_get */
	273,	/* ioprio_set */
	306,	/* kcmp */
	270,	/* kexec_load */
	241,	/* keyctl */
	60,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	92,	/* lchown */
	184,	/* lgetxattr */
	84,	/* link */
	255,	/* linkat */
	49,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	186,	/* listxattr */
	465,	/* listxattrat */
	187,	/* llistxattr */
	206,	/* lookup_dcookie */
	190,	/* lremovexattr */
	8,	/* lseek */
	181,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	6,	/* lstat */
	27,	/* madvise */
	453,	/* map_shadow_stack */
	227,	/* mbind */
	318,	/* membarrier */
	314,	/* memfd_create */
	246,	/* migrate_pages */
	26,	/* mincore */
	81,	/* mkdir */
	248,	/* mkdirat */
	131,	/* mknod */
	249,	/* mknodat */
	146,	/* mlock */
	319,	/* mlock2 */
	148,	/* mlockall */
	9,	/* mmap */
	160,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	267,	/* move_pages */
	10,	/* mprotect */
	235,	/* mq_getsetattr */
	234,	/* mq_notify */
	230,	/* mq_open */
	233,	/* mq_timedreceive */
	232,	/* mq_timedsend */
	231,	/* mq_unlink */
	24,	/* mremap */
	462,	/* mseal */
	69,	/* msgctl */
	66,	/* msgget */
	68,	/* msgrcv */
	67,	/* msgsnd */
	25,	/* msync */
	147,	/* munlock */
	149,	/* munlockall */
	11,	/* munmap */
	298,	/* name_to_handle_at */
	34,	/* nanosleep */
	252,	/* newfstatat */
	173,	/* nfsservctl */
	2,	/* open */
	299,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	247,	/* openat */
	437,	/* openat2 */
	33,	/* pause */
	292,	/* perf_event_open */
	132,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	21,	/* pipe */
	287,	/* pipe2 */
	151,	/* pivot_root */
	324,	/* pkey_alloc */
	325,	/* pkey_free */
	323,	/* pkey_mprotect */
	7,	/* poll */
	261,	/* ppoll */
	153,	/* prctl */
	16,	/* pread64 */
	289,	/* preadv */
	321,	/* preadv2 */
	297,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	304,	/* process_vm_readv */
	305,	/* process_vm_writev */
	260,	/* pselect6 */
	99,	/* ptrace */
	175,	/* putpmsg */
	17,	/* pwrite64 */
	290,	/* pwritev */
	322,	/* pwritev2 */
	171,	/* query_module */
	172,	/* quotactl */
	443,	/* quotactl_fd */
	0,	/* read */
	179,	/* readahead */
	87,	/* readlink */
	257,	/* readlinkat */
	18,	/* readv */
	164,	/* reboot */
	44,	/* recvfrom */
	294,	/* recvmmsg */
	46,	/* recvmsg */
	210,	/* remap_file_pages */
	189,	/* removexattr */
	466,	/* removexattrat */
	80,	/* rename */
	254,	/* renameat */
	311,	/* renameat2 */
	240,	/* request_key */
	177,	/* reserved177 */
	193,	/* reserved193 */
	213,	/* restart_syscall */
	82,	/* rmdir */
	327,	/* rseq */
	471,	/* rseq_slice_yield */
	13,	/* rt_sigaction */
	125,	/* rt_sigpending */
	14,	/* rt_sigprocmask */
	127,	/* rt_sigqueueinfo */
	211,	/* rt_sigreturn */
	128,	/* rt_sigsuspend */
	126,	/* rt_sigtimedwait */
	291,	/* rt_tgsigqueueinfo */
	143,	/* sched_get_priority_max */
	144,	/* sched_get_priority_min */
	196,	/* sched_getaffinity */
	310,	/* sched_getattr */
	140,	/* sched_getparam */
	142,	/* sched_getscheduler */
	145,	/* sched_rr_get_interval */
	195,	/* sched_setaffinity */
	309,	/* sched_setattr */
	139,	/* sched_setparam */
	141,	/* sched_setscheduler */
	23,	/* sched_yield */
	312,	/* seccomp */
	64,	/* semctl */
	62,	/* semget */
	63,	/* semop */
	214,	/* semtimedop */
	39,	/* sendfile */
	302,	/* sendmmsg */
	45,	/* sendmsg */
	43,	/* sendto */
	229,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	268,	/* set_robust_list */
	242,	/* set_thread_area */
	212,	/* set_tid_address */
	166,	/* setdomainname */
	121,	/* setfsgid */
	120,	/* setfsuid */
	104,	/* setgid */
	114,	/* setgroups */
	165,	/* sethostname */
	36,	/* setitimer */
	303,	/* setns */
	107,	/* setpgid */
	138,	/* setpriority */
	112,	/* setregid */
	117,	/* setresgid */
	115,	/* setresuid */
	111,	/* setreuid */
	155,	/* setrlimit */
	110,	/* setsid */
	53,	/* setsockopt */
	159,	/* settimeofday */
	103,	/* setuid */
	180,	/* setxattr */
	463,	/* setxattrat */
	29,	/* shmat */
	30,	/* shmctl */
	65,	/* shmdt */
	28,	/* shmget */
	47,	/* shutdown */
	129,	/* sigaltstack */
	276,	/* signalfd */
	283,	/* signalfd4 */
	40,	/* socket */
	52,	/* socketpair */
	263,	/* splice */
	4,	/* stat */
	134,	/* statfs */
	457,	/* statmount */
	326,	/* statx */
	163,	/* swapoff */
	162,	/* swapon */
	86,	/* symlink */
	256,	/* symlinkat */
	157,	/* sync */
	264,	/* sync_file_range */
	301,	/* syncfs */
	136,	/* sysfs */
	97,	/* sysinfo */
	101,	/* syslog */
	199,	/* sysmips */
	265,	/* tee */
	225,	/* tgkill */
	216,	/* timer_create */
	220,	/* timer_delete */
	219,	/* timer_getoverrun */
	218,	/* timer_gettime */
	217,	/* timer_settime */
	277,	/* timerfd */
	280,	/* timerfd_create */
	281,	/* timerfd_gettime */
	282,	/* timerfd_settime */
	98,	/* times */
	192,	/* tkill */
	74,	/* truncate */
	93,	/* umask */
	161,	/* umount2 */
	61,	/* uname */
	85,	/* unlink */
	253,	/* unlinkat */
	262,	/* unshare */
	317,	/* userfaultfd */
	133,	/* ustat */
	130,	/* utime */
	275,	/* utimensat */
	226,	/* utimes */
	150,	/* vhangup */
	266,	/* vmsplice */
	236,	/* vserver */
	59,	/* wait4 */
	237,	/* waitid */
	1,	/* write */
	19,	/* writev */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__mips__)

#if defined(ALL_SYSCALLTBL) || defined(__hppa__)
#if __BITS_PER_LONG != 64
static const char *const syscall_num_to_name_EM_PARISC[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "waitpid",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execve",
	[12] = "chdir",
	[13] = "time",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[17] = "socket",
	[18] = "stat",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "mount",
	[22] = "bind",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "stime",
	[26] = "ptrace",
	[27] = "alarm",
	[28] = "fstat",
	[29] = "pause",
	[30] = "utime",
	[31] = "connect",
	[32] = "listen",
	[33] = "access",
	[34] = "nice",
	[35] = "accept",
	[36] = "sync",
	[37] = "kill",
	[38] = "rename",
	[39] = "mkdir",
	[40] = "rmdir",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[44] = "getsockname",
	[45] = "brk",
	[46] = "setgid",
	[47] = "getgid",
	[48] = "signal",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[52] = "umount2",
	[53] = "getpeername",
	[54] = "ioctl",
	[55] = "fcntl",
	[56] = "socketpair",
	[57] = "setpgid",
	[58] = "send",
	[59] = "uname",
	[60] = "umask",
	[61] = "chroot",
	[62] = "ustat",
	[63] = "dup2",
	[64] = "getppid",
	[65] = "getpgrp",
	[66] = "setsid",
	[67] = "pivot_root",
	[68] = "sgetmask",
	[69] = "ssetmask",
	[70] = "setreuid",
	[71] = "setregid",
	[72] = "mincore",
	[73] = "sigpending",
	[74] = "sethostname",
	[75] = "setrlimit",
	[76] = "getrlimit",
	[77] = "getrusage",
	[78] = "gettimeofday",
	[79] = "settimeofday",
	[80] = "getgroups",
	[81] = "setgroups",
	[82] = "sendto",
	[83] = "symlink",
	[84] = "lstat",
	[85] = "readlink",
	[86] = "uselib",
	[87] = "swapon",
	[88] = "reboot",
	[89] = "mmap2",
	[90] = "mmap",
	[91] = "munmap",
	[92] = "truncate",
	[93] = "ftruncate",
	[94] = "fchmod",
	[95] = "fchown",
	[96] = "getpriority",
	[97] = "setpriority",
	[98] = "recv",
	[99] = "statfs",
	[100] = "fstatfs",
	[101] = "stat64",
	[103] = "syslog",
	[104] = "setitimer",
	[105] = "getitimer",
	[106] = "capget",
	[107] = "capset",
	[108] = "pread64",
	[109] = "pwrite64",
	[110] = "getcwd",
	[111] = "vhangup",
	[112] = "fstat64",
	[113] = "vfork",
	[114] = "wait4",
	[115] = "swapoff",
	[116] = "sysinfo",
	[117] = "shutdown",
	[118] = "fsync",
	[119] = "madvise",
	[120] = "clone",
	[121] = "setdomainname",
	[122] = "sendfile",
	[123] = "recvfrom",
	[124] = "adjtimex",
	[125] = "mprotect",
	[126] = "sigprocmask",
	[128] = "init_module",
	[129] = "delete_module",
	[131] = "quotactl",
	[132] = "getpgid",
	[133] = "fchdir",
	[134] = "bdflush",
	[135] = "sysfs",
	[136] = "personality",
	[138] = "setfsuid",
	[139] = "setfsgid",
	[140] = "_llseek",
	[141] = "getdents",
	[142] = "_newselect",
	[143] = "flock",
	[144] = "msync",
	[145] = "readv",
	[146] = "writev",
	[147] = "getsid",
	[148] = "fdatasync",
	[149] = "_sysctl",
	[150] = "mlock",
	[151] = "munlock",
	[152] = "mlockall",
	[153] = "munlockall",
	[154] = "sched_setparam",
	[155] = "sched_getparam",
	[156] = "sched_setscheduler",
	[157] = "sched_getscheduler",
	[158] = "sched_yield",
	[159] = "sched_get_priority_max",
	[160] = "sched_get_priority_min",
	[161] = "sched_rr_get_interval",
	[162] = "nanosleep",
	[163] = "mremap",
	[164] = "setresuid",
	[165] = "getresuid",
	[166] = "sigaltstack",
	[168] = "poll",
	[170] = "setresgid",
	[171] = "getresgid",
	[172] = "prctl",
	[173] = "rt_sigreturn",
	[174] = "rt_sigaction",
	[175] = "rt_sigprocmask",
	[176] = "rt_sigpending",
	[177] = "rt_sigtimedwait",
	[178] = "rt_sigqueueinfo",
	[179] = "rt_sigsuspend",
	[180] = "chown",
	[181] = "setsockopt",
	[182] = "getsockopt",
	[183] = "sendmsg",
	[184] = "recvmsg",
	[185] = "semop",
	[186] = "semget",
	[187] = "semctl",
	[188] = "msgsnd",
	[189] = "msgrcv",
	[190] = "msgget",
	[191] = "msgctl",
	[192] = "shmat",
	[193] = "shmdt",
	[194] = "shmget",
	[195] = "shmctl",
	[198] = "lstat64",
	[199] = "truncate64",
	[200] = "ftruncate64",
	[201] = "getdents64",
	[202] = "fcntl64",
	[206] = "gettid",
	[207] = "readahead",
	[208] = "tkill",
	[209] = "sendfile64",
	[210] = "futex",
	[211] = "sched_setaffinity",
	[212] = "sched_getaffinity",
	[215] = "io_setup",
	[216] = "io_destroy",
	[217] = "io_getevents",
	[218] = "io_submit",
	[219] = "io_cancel",
	[222] = "exit_group",
	[223] = "lookup_dcookie",
	[224] = "epoll_create",
	[225] = "epoll_ctl",
	[226] = "epoll_wait",
	[227] = "remap_file_pages",
	[228] = "semtimedop",
	[229] = "mq_open",
	[230] = "mq_unlink",
	[231] = "mq_timedsend",
	[232] = "mq_timedreceive",
	[233] = "mq_notify",
	[234] = "mq_getsetattr",
	[235] = "waitid",
	[236] = "fadvise64_64",
	[237] = "set_tid_address",
	[238] = "setxattr",
	[239] = "lsetxattr",
	[240] = "fsetxattr",
	[241] = "getxattr",
	[242] = "lgetxattr",
	[243] = "fgetxattr",
	[244] = "listxattr",
	[245] = "llistxattr",
	[246] = "flistxattr",
	[247] = "removexattr",
	[248] = "lremovexattr",
	[249] = "fremovexattr",
	[250] = "timer_create",
	[251] = "timer_settime",
	[252] = "timer_gettime",
	[253] = "timer_getoverrun",
	[254] = "timer_delete",
	[255] = "clock_settime",
	[256] = "clock_gettime",
	[257] = "clock_getres",
	[258] = "clock_nanosleep",
	[259] = "tgkill",
	[260] = "mbind",
	[261] = "get_mempolicy",
	[262] = "set_mempolicy",
	[264] = "add_key",
	[265] = "request_key",
	[266] = "keyctl",
	[267] = "ioprio_set",
	[268] = "ioprio_get",
	[269] = "inotify_init",
	[270] = "inotify_add_watch",
	[271] = "inotify_rm_watch",
	[272] = "migrate_pages",
	[273] = "pselect6",
	[274] = "ppoll",
	[275] = "openat",
	[276] = "mkdirat",
	[277] = "mknodat",
	[278] = "fchownat",
	[279] = "futimesat",
	[280] = "fstatat64",
	[281] = "unlinkat",
	[282] = "renameat",
	[283] = "linkat",
	[284] = "symlinkat",
	[285] = "readlinkat",
	[286] = "fchmodat",
	[287] = "faccessat",
	[288] = "unshare",
	[289] = "set_robust_list",
	[290] = "get_robust_list",
	[291] = "splice",
	[292] = "sync_file_range",
	[293] = "tee",
	[294] = "vmsplice",
	[295] = "move_pages",
	[296] = "getcpu",
	[297] = "epoll_pwait",
	[298] = "statfs64",
	[299] = "fstatfs64",
	[300] = "kexec_load",
	[301] = "utimensat",
	[302] = "signalfd",
	[304] = "eventfd",
	[305] = "fallocate",
	[306] = "timerfd_create",
	[307] = "timerfd_settime",
	[308] = "timerfd_gettime",
	[309] = "signalfd4",
	[310] = "eventfd2",
	[311] = "epoll_create1",
	[312] = "dup3",
	[313] = "pipe2",
	[314] = "inotify_init1",
	[315] = "preadv",
	[316] = "pwritev",
	[317] = "rt_tgsigqueueinfo",
	[318] = "perf_event_open",
	[319] = "recvmmsg",
	[320] = "accept4",
	[321] = "prlimit64",
	[322] = "fanotify_init",
	[323] = "fanotify_mark",
	[324] = "clock_adjtime",
	[325] = "name_to_handle_at",
	[326] = "open_by_handle_at",
	[327] = "syncfs",
	[328] = "setns",
	[329] = "sendmmsg",
	[330] = "process_vm_readv",
	[331] = "process_vm_writev",
	[332] = "kcmp",
	[333] = "finit_module",
	[334] = "sched_setattr",
	[335] = "sched_getattr",
	[336] = "utimes",
	[337] = "renameat2",
	[338] = "seccomp",
	[339] = "getrandom",
	[340] = "memfd_create",
	[341] = "bpf",
	[342] = "execveat",
	[343] = "membarrier",
	[344] = "userfaultfd",
	[345] = "mlock2",
	[346] = "copy_file_range",
	[347] = "preadv2",
	[348] = "pwritev2",
	[349] = "statx",
	[350] = "io_pgetevents",
	[351] = "pkey_mprotect",
	[352] = "pkey_alloc",
	[353] = "pkey_free",
	[354] = "rseq",
	[355] = "kexec_file_load",
	[356] = "cacheflush",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
};
static const uint16_t syscall_sorted_names_EM_PARISC[] = {
	140,	/* _llseek */
	142,	/* _newselect */
	149,	/* _sysctl */
	35,	/* accept */
	320,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	264,	/* add_key */
	124,	/* adjtimex */
	27,	/* alarm */
	134,	/* bdflush */
	22,	/* bind */
	341,	/* bpf */
	45,	/* brk */
	356,	/* cacheflush */
	451,	/* cachestat */
	106,	/* capget */
	107,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	180,	/* chown */
	61,	/* chroot */
	324,	/* clock_adjtime */
	405,	/* clock_adjtime64 */
	257,	/* clock_getres */
	406,	/* clock_getres_time64 */
	256,	/* clock_gettime */
	403,	/* clock_gettime64 */
	258,	/* clock_nanosleep */
	407,	/* clock_nanosleep_time64 */
	255,	/* clock_settime */
	404,	/* clock_settime64 */
	120,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	31,	/* connect */
	346,	/* copy_file_range */
	8,	/* creat */
	129,	/* delete_module */
	41,	/* dup */
	63,	/* dup2 */
	312,	/* dup3 */
	224,	/* epoll_create */
	311,	/* epoll_create1 */
	225,	/* epoll_ctl */
	297,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	226,	/* epoll_wait */
	304,	/* eventfd */
	310,	/* eventfd2 */
	11,	/* execve */
	342,	/* execveat */
	1,	/* exit */
	222,	/* exit_group */
	287,	/* faccessat */
	439,	/* faccessat2 */
	236,	/* fadvise64_64 */
	305,	/* fallocate */
	322,	/* fanotify_init */
	323,	/* fanotify_mark */
	133,	/* fchdir */
	94,	/* fchmod */
	286,	/* fchmodat */
	452,	/* fchmodat2 */
	95,	/* fchown */
	278,	/* fchownat */
	55,	/* fcntl */
	202,	/* fcntl64 */
	148,	/* fdatasync */
	243,	/* fgetxattr */
	333,	/* finit_module */
	246,	/* flistxattr */
	143,	/* flock */
	2,	/* fork */
	249,	/* fremovexattr */
	431,	/* fsconfig */
	240,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	28,	/* fstat */
	112,	/* fstat64 */
	280,	/* fstatat64 */
	100,	/* fstatfs */
	299,	/* fstatfs64 */
	118,	/* fsync */
	93,	/* ftruncate */
	200,	/* ftruncate64 */
	210,	/* futex */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	279,	/* futimesat */
	261,	/* get_mempolicy */
	290,	/* get_robust_list */
	296,	/* getcpu */
	110,	/* getcwd */
	141,	/* getdents */
	201,	/* getdents64 */
	50,	/* getegid */
	49,	/* geteuid */
	47,	/* getgid */
	80,	/* getgroups */
	105,	/* getitimer */
	53,	/* getpeername */
	132,	/* getpgid */
	65,	/* getpgrp */
	20,	/* getpid */
	64,	/* getppid */
	96,	/* getpriority */
	339,	/* getrandom */
	171,	/* getresgid */
	165,	/* getresuid */
	76,	/* getrlimit */
	77,	/* getrusage */
	147,	/* getsid */
	44,	/* getsockname */
	182,	/* getsockopt */
	206,	/* gettid */
	78,	/* gettimeofday */
	24,	/* getuid */
	241,	/* getxattr */
	128,	/* init_module */
	270,	/* inotify_add_watch */
	269,	/* inotify_init */
	314,	/* inotify_init1 */
	271,	/* inotify_rm_watch */
	219,	/* io_cancel */
	216,	/* io_destroy */
	217,	/* io_getevents */
	350,	/* io_pgetevents */
	416,	/* io_pgetevents_time64 */
	215,	/* io_setup */
	218,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	268,	/* ioprio_get */
	267,	/* ioprio_set */
	332,	/* kcmp */
	355,	/* kexec_file_load */
	300,	/* kexec_load */
	266,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	242,	/* lgetxattr */
	9,	/* link */
	283,	/* linkat */
	32,	/* listen */
	458,	/* listmount */
	244,	/* listxattr */
	245,	/* llistxattr */
	223,	/* lookup_dcookie */
	248,	/* lremovexattr */
	19,	/* lseek */
	239,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	84,	/* lstat */
	198,	/* lstat64 */
	119,	/* madvise */
	453,	/* map_shadow_stack */
	260,	/* mbind */
	343,	/* membarrier */
	340,	/* memfd_create */
	272,	/* migrate_pages */
	72,	/* mincore */
	39,	/* mkdir */
	276,	/* mkdirat */
	14,	/* mknod */
	277,	/* mknodat */
	150,	/* mlock */
	345,	/* mlock2 */
	152,	/* mlockall */
	90,	/* mmap */
	89,	/* mmap2 */
	21,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	295,	/* move_pages */
	125,	/* mprotect */
	234,	/* mq_getsetattr */
	233,	/* mq_notify */
	229,	/* mq_open */
	232,	/* mq_timedreceive */
	419,	/* mq_timedreceive_time64 */
	231,	/* mq_timedsend */
	418,	/* mq_timedsend_time64 */
	230,	/* mq_unlink */
	163,	/* mremap */
	462,	/* mseal */
	191,	/* msgctl */
	190,	/* msgget */
	189,	/* msgrcv */
	188,	/* msgsnd */
	144,	/* msync */
	151,	/* munlock */
	153,	/* munlockall */
	91,	/* munmap */
	325,	/* name_to_handle_at */
	162,	/* nanosleep */
	34,	/* nice */
	5,	/* open */
	326,	/* open_by_handle_at */
	428,	/* open_tree */
	275,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	318,	/* perf_event_open */
	136,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	313,	/* pipe2 */
	67,	/* pivot_root */
	352,	/* pkey_alloc */
	353,	/* pkey_free */
	351,	/* pkey_mprotect */
	168,	/* poll */
	274,	/* ppoll */
	414,	/* ppoll_time64 */
	172,	/* prctl */
	108,	/* pread64 */
	315,	/* preadv */
	347,	/* preadv2 */
	321,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	330,	/* process_vm_readv */
	331,	/* process_vm_writev */
	273,	/* pselect6 */
	413,	/* pselect6_time64 */
	26,	/* ptrace */
	109,	/* pwrite64 */
	316,	/* pwritev */
	348,	/* pwritev2 */
	131,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	207,	/* readahead */
	85,	/* readlink */
	285,	/* readlinkat */
	145,	/* readv */
	88,	/* reboot */
	98,	/* recv */
	123,	/* recvfrom */
	319,	/* recvmmsg */
	417,	/* recvmmsg_time64 */
	184,	/* recvmsg */
	227,	/* remap_file_pages */
	247,	/* removexattr */
	38,	/* rename */
	282,	/* renameat */
	337,	/* renameat2 */
	265,	/* request_key */
	0,	/* restart_syscall */
	40,	/* rmdir */
	354,	/* rseq */
	174,	/* rt_sigaction */
	176,	/* rt_sigpending */
	175,	/* rt_sigprocmask */
	178,	/* rt_sigqueueinfo */
	173,	/* rt_sigreturn */
	179,	/* rt_sigsuspend */
	177,	/* rt_sigtimedwait */
	421,	/* rt_sigtimedwait_time64 */
	317,	/* rt_tgsigqueueinfo */
	159,	/* sched_get_priority_max */
	160,	/* sched_get_priority_min */
	212,	/* sched_getaffinity */
	335,	/* sched_getattr */
	155,	/* sched_getparam */
	157,	/* sched_getscheduler */
	161,	/* sched_rr_get_interval */
	423,	/* sched_rr_get_interval_time64 */
	211,	/* sched_setaffinity */
	334,	/* sched_setattr */
	154,	/* sched_setparam */
	156,	/* sched_setscheduler */
	158,	/* sched_yield */
	338,	/* seccomp */
	187,	/* semctl */
	186,	/* semget */
	185,	/* semop */
	228,	/* semtimedop */
	420,	/* semtimedop_time64 */
	58,	/* send */
	122,	/* sendfile */
	209,	/* sendfile64 */
	329,	/* sendmmsg */
	183,	/* sendmsg */
	82,	/* sendto */
	262,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	289,	/* set_robust_list */
	237,	/* set_tid_address */
	121,	/* setdomainname */
	139,	/* setfsgid */
	138,	/* setfsuid */
	46,	/* setgid */
	81,	/* setgroups */
	74,	/* sethostname */
	104,	/* setitimer */
	328,	/* setns */
	57,	/* setpgid */
	97,	/* setpriority */
	71,	/* setregid */
	170,	/* setresgid */
	164,	/* setresuid */
	70,	/* setreuid */
	75,	/* setrlimit */
	66,	/* setsid */
	181,	/* setsockopt */
	79,	/* settimeofday */
	23,	/* setuid */
	238,	/* setxattr */
	68,	/* sgetmask */
	192,	/* shmat */
	195,	/* shmctl */
	193,	/* shmdt */
	194,	/* shmget */
	117,	/* shutdown */
	166,	/* sigaltstack */
	48,	/* signal */
	302,	/* signalfd */
	309,	/* signalfd4 */
	73,	/* sigpending */
	126,	/* sigprocmask */
	17,	/* socket */
	56,	/* socketpair */
	291,	/* splice */
	69,	/* ssetmask */
	18,	/* stat */
	101,	/* stat64 */
	99,	/* statfs */
	298,	/* statfs64 */
	457,	/* statmount */
	349,	/* statx */
	25,	/* stime */
	115,	/* swapoff */
	87,	/* swapon */
	83,	/* symlink */
	284,	/* symlinkat */
	36,	/* sync */
	292,	/* sync_file_range */
	327,	/* syncfs */
	135,	/* sysfs */
	116,	/* sysinfo */
	103,	/* syslog */
	293,	/* tee */
	259,	/* tgkill */
	13,	/* time */
	250,	/* timer_create */
	254,	/* timer_delete */
	253,	/* timer_getoverrun */
	252,	/* timer_gettime */
	408,	/* timer_gettime64 */
	251,	/* timer_settime */
	409,	/* timer_settime64 */
	306,	/* timerfd_create */
	308,	/* timerfd_gettime */
	410,	/* timerfd_gettime64 */
	307,	/* timerfd_settime */
	411,	/* timerfd_settime64 */
	43,	/* times */
	208,	/* tkill */
	92,	/* truncate */
	199,	/* truncate64 */
	60,	/* umask */
	52,	/* umount2 */
	59,	/* uname */
	10,	/* unlink */
	281,	/* unlinkat */
	288,	/* unshare */
	86,	/* uselib */
	344,	/* userfaultfd */
	62,	/* ustat */
	30,	/* utime */
	301,	/* utimensat */
	412,	/* utimensat_time64 */
	336,	/* utimes */
	113,	/* vfork */
	111,	/* vhangup */
	294,	/* vmsplice */
	114,	/* wait4 */
	235,	/* waitid */
	7,	/* waitpid */
	4,	/* write */
	146,	/* writev */
};
#else
static const char *const syscall_num_to_name_EM_PARISC[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "waitpid",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execve",
	[12] = "chdir",
	[13] = "time",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[17] = "socket",
	[18] = "stat",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "mount",
	[22] = "bind",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "stime",
	[26] = "ptrace",
	[27] = "alarm",
	[28] = "fstat",
	[29] = "pause",
	[30] = "utime",
	[31] = "connect",
	[32] = "listen",
	[33] = "access",
	[34] = "nice",
	[35] = "accept",
	[36] = "sync",
	[37] = "kill",
	[38] = "rename",
	[39] = "mkdir",
	[40] = "rmdir",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[44] = "getsockname",
	[45] = "brk",
	[46] = "setgid",
	[47] = "getgid",
	[48] = "signal",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[52] = "umount2",
	[53] = "getpeername",
	[54] = "ioctl",
	[55] = "fcntl",
	[56] = "socketpair",
	[57] = "setpgid",
	[58] = "send",
	[59] = "uname",
	[60] = "umask",
	[61] = "chroot",
	[62] = "ustat",
	[63] = "dup2",
	[64] = "getppid",
	[65] = "getpgrp",
	[66] = "setsid",
	[67] = "pivot_root",
	[68] = "sgetmask",
	[69] = "ssetmask",
	[70] = "setreuid",
	[71] = "setregid",
	[72] = "mincore",
	[73] = "sigpending",
	[74] = "sethostname",
	[75] = "setrlimit",
	[76] = "getrlimit",
	[77] = "getrusage",
	[78] = "gettimeofday",
	[79] = "settimeofday",
	[80] = "getgroups",
	[81] = "setgroups",
	[82] = "sendto",
	[83] = "symlink",
	[84] = "lstat",
	[85] = "readlink",
	[86] = "uselib",
	[87] = "swapon",
	[88] = "reboot",
	[89] = "mmap2",
	[90] = "mmap",
	[91] = "munmap",
	[92] = "truncate",
	[93] = "ftruncate",
	[94] = "fchmod",
	[95] = "fchown",
	[96] = "getpriority",
	[97] = "setpriority",
	[98] = "recv",
	[99] = "statfs",
	[100] = "fstatfs",
	[101] = "stat64",
	[103] = "syslog",
	[104] = "setitimer",
	[105] = "getitimer",
	[106] = "capget",
	[107] = "capset",
	[108] = "pread64",
	[109] = "pwrite64",
	[110] = "getcwd",
	[111] = "vhangup",
	[112] = "fstat64",
	[113] = "vfork",
	[114] = "wait4",
	[115] = "swapoff",
	[116] = "sysinfo",
	[117] = "shutdown",
	[118] = "fsync",
	[119] = "madvise",
	[120] = "clone",
	[121] = "setdomainname",
	[122] = "sendfile",
	[123] = "recvfrom",
	[124] = "adjtimex",
	[125] = "mprotect",
	[126] = "sigprocmask",
	[128] = "init_module",
	[129] = "delete_module",
	[131] = "quotactl",
	[132] = "getpgid",
	[133] = "fchdir",
	[134] = "bdflush",
	[135] = "sysfs",
	[136] = "personality",
	[138] = "setfsuid",
	[139] = "setfsgid",
	[140] = "_llseek",
	[141] = "getdents",
	[142] = "_newselect",
	[143] = "flock",
	[144] = "msync",
	[145] = "readv",
	[146] = "writev",
	[147] = "getsid",
	[148] = "fdatasync",
	[149] = "_sysctl",
	[150] = "mlock",
	[151] = "munlock",
	[152] = "mlockall",
	[153] = "munlockall",
	[154] = "sched_setparam",
	[155] = "sched_getparam",
	[156] = "sched_setscheduler",
	[157] = "sched_getscheduler",
	[158] = "sched_yield",
	[159] = "sched_get_priority_max",
	[160] = "sched_get_priority_min",
	[161] = "sched_rr_get_interval",
	[162] = "nanosleep",
	[163] = "mremap",
	[164] = "setresuid",
	[165] = "getresuid",
	[166] = "sigaltstack",
	[168] = "poll",
	[170] = "setresgid",
	[171] = "getresgid",
	[172] = "prctl",
	[173] = "rt_sigreturn",
	[174] = "rt_sigaction",
	[175] = "rt_sigprocmask",
	[176] = "rt_sigpending",
	[177] = "rt_sigtimedwait",
	[178] = "rt_sigqueueinfo",
	[179] = "rt_sigsuspend",
	[180] = "chown",
	[181] = "setsockopt",
	[182] = "getsockopt",
	[183] = "sendmsg",
	[184] = "recvmsg",
	[185] = "semop",
	[186] = "semget",
	[187] = "semctl",
	[188] = "msgsnd",
	[189] = "msgrcv",
	[190] = "msgget",
	[191] = "msgctl",
	[192] = "shmat",
	[193] = "shmdt",
	[194] = "shmget",
	[195] = "shmctl",
	[198] = "lstat64",
	[199] = "truncate64",
	[200] = "ftruncate64",
	[201] = "getdents64",
	[202] = "fcntl64",
	[206] = "gettid",
	[207] = "readahead",
	[208] = "tkill",
	[209] = "sendfile64",
	[210] = "futex",
	[211] = "sched_setaffinity",
	[212] = "sched_getaffinity",
	[215] = "io_setup",
	[216] = "io_destroy",
	[217] = "io_getevents",
	[218] = "io_submit",
	[219] = "io_cancel",
	[222] = "exit_group",
	[223] = "lookup_dcookie",
	[224] = "epoll_create",
	[225] = "epoll_ctl",
	[226] = "epoll_wait",
	[227] = "remap_file_pages",
	[228] = "semtimedop",
	[229] = "mq_open",
	[230] = "mq_unlink",
	[231] = "mq_timedsend",
	[232] = "mq_timedreceive",
	[233] = "mq_notify",
	[234] = "mq_getsetattr",
	[235] = "waitid",
	[236] = "fadvise64_64",
	[237] = "set_tid_address",
	[238] = "setxattr",
	[239] = "lsetxattr",
	[240] = "fsetxattr",
	[241] = "getxattr",
	[242] = "lgetxattr",
	[243] = "fgetxattr",
	[244] = "listxattr",
	[245] = "llistxattr",
	[246] = "flistxattr",
	[247] = "removexattr",
	[248] = "lremovexattr",
	[249] = "fremovexattr",
	[250] = "timer_create",
	[251] = "timer_settime",
	[252] = "timer_gettime",
	[253] = "timer_getoverrun",
	[254] = "timer_delete",
	[255] = "clock_settime",
	[256] = "clock_gettime",
	[257] = "clock_getres",
	[258] = "clock_nanosleep",
	[259] = "tgkill",
	[260] = "mbind",
	[261] = "get_mempolicy",
	[262] = "set_mempolicy",
	[264] = "add_key",
	[265] = "request_key",
	[266] = "keyctl",
	[267] = "ioprio_set",
	[268] = "ioprio_get",
	[269] = "inotify_init",
	[270] = "inotify_add_watch",
	[271] = "inotify_rm_watch",
	[272] = "migrate_pages",
	[273] = "pselect6",
	[274] = "ppoll",
	[275] = "openat",
	[276] = "mkdirat",
	[277] = "mknodat",
	[278] = "fchownat",
	[279] = "futimesat",
	[280] = "fstatat64",
	[281] = "unlinkat",
	[282] = "renameat",
	[283] = "linkat",
	[284] = "symlinkat",
	[285] = "readlinkat",
	[286] = "fchmodat",
	[287] = "faccessat",
	[288] = "unshare",
	[289] = "set_robust_list",
	[290] = "get_robust_list",
	[291] = "splice",
	[292] = "sync_file_range",
	[293] = "tee",
	[294] = "vmsplice",
	[295] = "move_pages",
	[296] = "getcpu",
	[297] = "epoll_pwait",
	[298] = "statfs64",
	[299] = "fstatfs64",
	[300] = "kexec_load",
	[301] = "utimensat",
	[302] = "signalfd",
	[304] = "eventfd",
	[305] = "fallocate",
	[306] = "timerfd_create",
	[307] = "timerfd_settime",
	[308] = "timerfd_gettime",
	[309] = "signalfd4",
	[310] = "eventfd2",
	[311] = "epoll_create1",
	[312] = "dup3",
	[313] = "pipe2",
	[314] = "inotify_init1",
	[315] = "preadv",
	[316] = "pwritev",
	[317] = "rt_tgsigqueueinfo",
	[318] = "perf_event_open",
	[319] = "recvmmsg",
	[320] = "accept4",
	[321] = "prlimit64",
	[322] = "fanotify_init",
	[323] = "fanotify_mark",
	[324] = "clock_adjtime",
	[325] = "name_to_handle_at",
	[326] = "open_by_handle_at",
	[327] = "syncfs",
	[328] = "setns",
	[329] = "sendmmsg",
	[330] = "process_vm_readv",
	[331] = "process_vm_writev",
	[332] = "kcmp",
	[333] = "finit_module",
	[334] = "sched_setattr",
	[335] = "sched_getattr",
	[336] = "utimes",
	[337] = "renameat2",
	[338] = "seccomp",
	[339] = "getrandom",
	[340] = "memfd_create",
	[341] = "bpf",
	[342] = "execveat",
	[343] = "membarrier",
	[344] = "userfaultfd",
	[345] = "mlock2",
	[346] = "copy_file_range",
	[347] = "preadv2",
	[348] = "pwritev2",
	[349] = "statx",
	[350] = "io_pgetevents",
	[351] = "pkey_mprotect",
	[352] = "pkey_alloc",
	[353] = "pkey_free",
	[354] = "rseq",
	[355] = "kexec_file_load",
	[356] = "cacheflush",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
};
static const uint16_t syscall_sorted_names_EM_PARISC[] = {
	140,	/* _llseek */
	142,	/* _newselect */
	149,	/* _sysctl */
	35,	/* accept */
	320,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	264,	/* add_key */
	124,	/* adjtimex */
	27,	/* alarm */
	134,	/* bdflush */
	22,	/* bind */
	341,	/* bpf */
	45,	/* brk */
	356,	/* cacheflush */
	451,	/* cachestat */
	106,	/* capget */
	107,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	180,	/* chown */
	61,	/* chroot */
	324,	/* clock_adjtime */
	257,	/* clock_getres */
	256,	/* clock_gettime */
	258,	/* clock_nanosleep */
	255,	/* clock_settime */
	120,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	31,	/* connect */
	346,	/* copy_file_range */
	8,	/* creat */
	129,	/* delete_module */
	41,	/* dup */
	63,	/* dup2 */
	312,	/* dup3 */
	224,	/* epoll_create */
	311,	/* epoll_create1 */
	225,	/* epoll_ctl */
	297,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	226,	/* epoll_wait */
	304,	/* eventfd */
	310,	/* eventfd2 */
	11,	/* execve */
	342,	/* execveat */
	1,	/* exit */
	222,	/* exit_group */
	287,	/* faccessat */
	439,	/* faccessat2 */
	236,	/* fadvise64_64 */
	305,	/* fallocate */
	322,	/* fanotify_init */
	323,	/* fanotify_mark */
	133,	/* fchdir */
	94,	/* fchmod */
	286,	/* fchmodat */
	452,	/* fchmodat2 */
	95,	/* fchown */
	278,	/* fchownat */
	55,	/* fcntl */
	202,	/* fcntl64 */
	148,	/* fdatasync */
	243,	/* fgetxattr */
	333,	/* finit_module */
	246,	/* flistxattr */
	143,	/* flock */
	2,	/* fork */
	249,	/* fremovexattr */
	431,	/* fsconfig */
	240,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	28,	/* fstat */
	112,	/* fstat64 */
	280,	/* fstatat64 */
	100,	/* fstatfs */
	299,	/* fstatfs64 */
	118,	/* fsync */
	93,	/* ftruncate */
	200,	/* ftruncate64 */
	210,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	279,	/* futimesat */
	261,	/* get_mempolicy */
	290,	/* get_robust_list */
	296,	/* getcpu */
	110,	/* getcwd */
	141,	/* getdents */
	201,	/* getdents64 */
	50,	/* getegid */
	49,	/* geteuid */
	47,	/* getgid */
	80,	/* getgroups */
	105,	/* getitimer */
	53,	/* getpeername */
	132,	/* getpgid */
	65,	/* getpgrp */
	20,	/* getpid */
	64,	/* getppid */
	96,	/* getpriority */
	339,	/* getrandom */
	171,	/* getresgid */
	165,	/* getresuid */
	76,	/* getrlimit */
	77,	/* getrusage */
	147,	/* getsid */
	44,	/* getsockname */
	182,	/* getsockopt */
	206,	/* gettid */
	78,	/* gettimeofday */
	24,	/* getuid */
	241,	/* getxattr */
	128,	/* init_module */
	270,	/* inotify_add_watch */
	269,	/* inotify_init */
	314,	/* inotify_init1 */
	271,	/* inotify_rm_watch */
	219,	/* io_cancel */
	216,	/* io_destroy */
	217,	/* io_getevents */
	350,	/* io_pgetevents */
	215,	/* io_setup */
	218,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	268,	/* ioprio_get */
	267,	/* ioprio_set */
	332,	/* kcmp */
	355,	/* kexec_file_load */
	300,	/* kexec_load */
	266,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	242,	/* lgetxattr */
	9,	/* link */
	283,	/* linkat */
	32,	/* listen */
	458,	/* listmount */
	244,	/* listxattr */
	245,	/* llistxattr */
	223,	/* lookup_dcookie */
	248,	/* lremovexattr */
	19,	/* lseek */
	239,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	84,	/* lstat */
	198,	/* lstat64 */
	119,	/* madvise */
	453,	/* map_shadow_stack */
	260,	/* mbind */
	343,	/* membarrier */
	340,	/* memfd_create */
	272,	/* migrate_pages */
	72,	/* mincore */
	39,	/* mkdir */
	276,	/* mkdirat */
	14,	/* mknod */
	277,	/* mknodat */
	150,	/* mlock */
	345,	/* mlock2 */
	152,	/* mlockall */
	90,	/* mmap */
	89,	/* mmap2 */
	21,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	295,	/* move_pages */
	125,	/* mprotect */
	234,	/* mq_getsetattr */
	233,	/* mq_notify */
	229,	/* mq_open */
	232,	/* mq_timedreceive */
	231,	/* mq_timedsend */
	230,	/* mq_unlink */
	163,	/* mremap */
	462,	/* mseal */
	191,	/* msgctl */
	190,	/* msgget */
	189,	/* msgrcv */
	188,	/* msgsnd */
	144,	/* msync */
	151,	/* munlock */
	153,	/* munlockall */
	91,	/* munmap */
	325,	/* name_to_handle_at */
	162,	/* nanosleep */
	34,	/* nice */
	5,	/* open */
	326,	/* open_by_handle_at */
	428,	/* open_tree */
	275,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	318,	/* perf_event_open */
	136,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	313,	/* pipe2 */
	67,	/* pivot_root */
	352,	/* pkey_alloc */
	353,	/* pkey_free */
	351,	/* pkey_mprotect */
	168,	/* poll */
	274,	/* ppoll */
	172,	/* prctl */
	108,	/* pread64 */
	315,	/* preadv */
	347,	/* preadv2 */
	321,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	330,	/* process_vm_readv */
	331,	/* process_vm_writev */
	273,	/* pselect6 */
	26,	/* ptrace */
	109,	/* pwrite64 */
	316,	/* pwritev */
	348,	/* pwritev2 */
	131,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	207,	/* readahead */
	85,	/* readlink */
	285,	/* readlinkat */
	145,	/* readv */
	88,	/* reboot */
	98,	/* recv */
	123,	/* recvfrom */
	319,	/* recvmmsg */
	184,	/* recvmsg */
	227,	/* remap_file_pages */
	247,	/* removexattr */
	38,	/* rename */
	282,	/* renameat */
	337,	/* renameat2 */
	265,	/* request_key */
	0,	/* restart_syscall */
	40,	/* rmdir */
	354,	/* rseq */
	174,	/* rt_sigaction */
	176,	/* rt_sigpending */
	175,	/* rt_sigprocmask */
	178,	/* rt_sigqueueinfo */
	173,	/* rt_sigreturn */
	179,	/* rt_sigsuspend */
	177,	/* rt_sigtimedwait */
	317,	/* rt_tgsigqueueinfo */
	159,	/* sched_get_priority_max */
	160,	/* sched_get_priority_min */
	212,	/* sched_getaffinity */
	335,	/* sched_getattr */
	155,	/* sched_getparam */
	157,	/* sched_getscheduler */
	161,	/* sched_rr_get_interval */
	211,	/* sched_setaffinity */
	334,	/* sched_setattr */
	154,	/* sched_setparam */
	156,	/* sched_setscheduler */
	158,	/* sched_yield */
	338,	/* seccomp */
	187,	/* semctl */
	186,	/* semget */
	185,	/* semop */
	228,	/* semtimedop */
	58,	/* send */
	122,	/* sendfile */
	209,	/* sendfile64 */
	329,	/* sendmmsg */
	183,	/* sendmsg */
	82,	/* sendto */
	262,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	289,	/* set_robust_list */
	237,	/* set_tid_address */
	121,	/* setdomainname */
	139,	/* setfsgid */
	138,	/* setfsuid */
	46,	/* setgid */
	81,	/* setgroups */
	74,	/* sethostname */
	104,	/* setitimer */
	328,	/* setns */
	57,	/* setpgid */
	97,	/* setpriority */
	71,	/* setregid */
	170,	/* setresgid */
	164,	/* setresuid */
	70,	/* setreuid */
	75,	/* setrlimit */
	66,	/* setsid */
	181,	/* setsockopt */
	79,	/* settimeofday */
	23,	/* setuid */
	238,	/* setxattr */
	68,	/* sgetmask */
	192,	/* shmat */
	195,	/* shmctl */
	193,	/* shmdt */
	194,	/* shmget */
	117,	/* shutdown */
	166,	/* sigaltstack */
	48,	/* signal */
	302,	/* signalfd */
	309,	/* signalfd4 */
	73,	/* sigpending */
	126,	/* sigprocmask */
	17,	/* socket */
	56,	/* socketpair */
	291,	/* splice */
	69,	/* ssetmask */
	18,	/* stat */
	101,	/* stat64 */
	99,	/* statfs */
	298,	/* statfs64 */
	457,	/* statmount */
	349,	/* statx */
	25,	/* stime */
	115,	/* swapoff */
	87,	/* swapon */
	83,	/* symlink */
	284,	/* symlinkat */
	36,	/* sync */
	292,	/* sync_file_range */
	327,	/* syncfs */
	135,	/* sysfs */
	116,	/* sysinfo */
	103,	/* syslog */
	293,	/* tee */
	259,	/* tgkill */
	13,	/* time */
	250,	/* timer_create */
	254,	/* timer_delete */
	253,	/* timer_getoverrun */
	252,	/* timer_gettime */
	251,	/* timer_settime */
	306,	/* timerfd_create */
	308,	/* timerfd_gettime */
	307,	/* timerfd_settime */
	43,	/* times */
	208,	/* tkill */
	92,	/* truncate */
	199,	/* truncate64 */
	60,	/* umask */
	52,	/* umount2 */
	59,	/* uname */
	10,	/* unlink */
	281,	/* unlinkat */
	288,	/* unshare */
	86,	/* uselib */
	344,	/* userfaultfd */
	62,	/* ustat */
	30,	/* utime */
	301,	/* utimensat */
	336,	/* utimes */
	113,	/* vfork */
	111,	/* vhangup */
	294,	/* vmsplice */
	114,	/* wait4 */
	235,	/* waitid */
	7,	/* waitpid */
	4,	/* write */
	146,	/* writev */
};
#endif //__BITS_PER_LONG != 64
#endif // defined(ALL_SYSCALLTBL) || defined(__hppa__)

#if defined(ALL_SYSCALLTBL) || defined(__powerpc__) || defined(__powerpc64__)
static const char *const syscall_num_to_name_EM_PPC[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "waitpid",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execve",
	[12] = "chdir",
	[13] = "time",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[17] = "break",
	[18] = "oldstat",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "mount",
	[22] = "umount",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "stime",
	[26] = "ptrace",
	[27] = "alarm",
	[28] = "oldfstat",
	[29] = "pause",
	[30] = "utime",
	[31] = "stty",
	[32] = "gtty",
	[33] = "access",
	[34] = "nice",
	[35] = "ftime",
	[36] = "sync",
	[37] = "kill",
	[38] = "rename",
	[39] = "mkdir",
	[40] = "rmdir",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[44] = "prof",
	[45] = "brk",
	[46] = "setgid",
	[47] = "getgid",
	[48] = "signal",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[52] = "umount2",
	[53] = "lock",
	[54] = "ioctl",
	[55] = "fcntl",
	[56] = "mpx",
	[57] = "setpgid",
	[58] = "ulimit",
	[59] = "oldolduname",
	[60] = "umask",
	[61] = "chroot",
	[62] = "ustat",
	[63] = "dup2",
	[64] = "getppid",
	[65] = "getpgrp",
	[66] = "setsid",
	[67] = "sigaction",
	[68] = "sgetmask",
	[69] = "ssetmask",
	[70] = "setreuid",
	[71] = "setregid",
	[72] = "sigsuspend",
	[73] = "sigpending",
	[74] = "sethostname",
	[75] = "setrlimit",
	[76] = "getrlimit",
	[77] = "getrusage",
	[78] = "gettimeofday",
	[79] = "settimeofday",
	[80] = "getgroups",
	[81] = "setgroups",
	[82] = "select",
	[83] = "symlink",
	[84] = "oldlstat",
	[85] = "readlink",
	[86] = "uselib",
	[87] = "swapon",
	[88] = "reboot",
	[89] = "readdir",
	[90] = "mmap",
	[91] = "munmap",
	[92] = "truncate",
	[93] = "ftruncate",
	[94] = "fchmod",
	[95] = "fchown",
	[96] = "getpriority",
	[97] = "setpriority",
	[98] = "profil",
	[99] = "statfs",
	[100] = "fstatfs",
	[101] = "ioperm",
	[102] = "socketcall",
	[103] = "syslog",
	[104] = "setitimer",
	[105] = "getitimer",
	[106] = "stat",
	[107] = "lstat",
	[108] = "fstat",
	[109] = "olduname",
	[110] = "iopl",
	[111] = "vhangup",
	[112] = "idle",
	[113] = "vm86",
	[114] = "wait4",
	[115] = "swapoff",
	[116] = "sysinfo",
	[117] = "ipc",
	[118] = "fsync",
	[119] = "sigreturn",
	[120] = "clone",
	[121] = "setdomainname",
	[122] = "uname",
	[123] = "modify_ldt",
	[124] = "adjtimex",
	[125] = "mprotect",
	[126] = "sigprocmask",
	[127] = "create_module",
	[128] = "init_module",
	[129] = "delete_module",
	[130] = "get_kernel_syms",
	[131] = "quotactl",
	[132] = "getpgid",
	[133] = "fchdir",
	[134] = "bdflush",
	[135] = "sysfs",
	[136] = "personality",
	[137] = "afs_syscall",
	[138] = "setfsuid",
	[139] = "setfsgid",
	[140] = "_llseek",
	[141] = "getdents",
	[142] = "_newselect",
	[143] = "flock",
	[144] = "msync",
	[145] = "readv",
	[146] = "writev",
	[147] = "getsid",
	[148] = "fdatasync",
	[149] = "_sysctl",
	[150] = "mlock",
	[151] = "munlock",
	[152] = "mlockall",
	[153] = "munlockall",
	[154] = "sched_setparam",
	[155] = "sched_getparam",
	[156] = "sched_setscheduler",
	[157] = "sched_getscheduler",
	[158] = "sched_yield",
	[159] = "sched_get_priority_max",
	[160] = "sched_get_priority_min",
	[161] = "sched_rr_get_interval",
	[162] = "nanosleep",
	[163] = "mremap",
	[164] = "setresuid",
	[165] = "getresuid",
	[166] = "query_module",
	[167] = "poll",
	[168] = "nfsservctl",
	[169] = "setresgid",
	[170] = "getresgid",
	[171] = "prctl",
	[172] = "rt_sigreturn",
	[173] = "rt_sigaction",
	[174] = "rt_sigprocmask",
	[175] = "rt_sigpending",
	[176] = "rt_sigtimedwait",
	[177] = "rt_sigqueueinfo",
	[178] = "rt_sigsuspend",
	[179] = "pread64",
	[180] = "pwrite64",
	[181] = "chown",
	[182] = "getcwd",
	[183] = "capget",
	[184] = "capset",
	[185] = "sigaltstack",
	[186] = "sendfile",
	[187] = "getpmsg",
	[188] = "putpmsg",
	[189] = "vfork",
	[190] = "ugetrlimit",
	[191] = "readahead",
	[192] = "mmap2",
	[193] = "truncate64",
	[194] = "ftruncate64",
	[195] = "stat64",
	[196] = "lstat64",
	[197] = "fstat64",
	[198] = "pciconfig_read",
	[199] = "pciconfig_write",
	[200] = "pciconfig_iobase",
	[201] = "multiplexer",
	[202] = "getdents64",
	[203] = "pivot_root",
	[204] = "fcntl64",
	[205] = "madvise",
	[206] = "mincore",
	[207] = "gettid",
	[208] = "tkill",
	[209] = "setxattr",
	[210] = "lsetxattr",
	[211] = "fsetxattr",
	[212] = "getxattr",
	[213] = "lgetxattr",
	[214] = "fgetxattr",
	[215] = "listxattr",
	[216] = "llistxattr",
	[217] = "flistxattr",
	[218] = "removexattr",
	[219] = "lremovexattr",
	[220] = "fremovexattr",
	[221] = "futex",
	[222] = "sched_setaffinity",
	[223] = "sched_getaffinity",
	[225] = "tuxcall",
	[226] = "sendfile64",
	[227] = "io_setup",
	[228] = "io_destroy",
	[229] = "io_getevents",
	[230] = "io_submit",
	[231] = "io_cancel",
	[232] = "set_tid_address",
	[233] = "fadvise64",
	[234] = "exit_group",
	[235] = "lookup_dcookie",
	[236] = "epoll_create",
	[237] = "epoll_ctl",
	[238] = "epoll_wait",
	[239] = "remap_file_pages",
	[240] = "timer_create",
	[241] = "timer_settime",
	[242] = "timer_gettime",
	[243] = "timer_getoverrun",
	[244] = "timer_delete",
	[245] = "clock_settime",
	[246] = "clock_gettime",
	[247] = "clock_getres",
	[248] = "clock_nanosleep",
	[249] = "swapcontext",
	[250] = "tgkill",
	[251] = "utimes",
	[252] = "statfs64",
	[253] = "fstatfs64",
	[254] = "fadvise64_64",
	[255] = "rtas",
	[256] = "sys_debug_setcontext",
	[258] = "migrate_pages",
	[259] = "mbind",
	[260] = "get_mempolicy",
	[261] = "set_mempolicy",
	[262] = "mq_open",
	[263] = "mq_unlink",
	[264] = "mq_timedsend",
	[265] = "mq_timedreceive",
	[266] = "mq_notify",
	[267] = "mq_getsetattr",
	[268] = "kexec_load",
	[269] = "add_key",
	[270] = "request_key",
	[271] = "keyctl",
	[272] = "waitid",
	[273] = "ioprio_set",
	[274] = "ioprio_get",
	[275] = "inotify_init",
	[276] = "inotify_add_watch",
	[277] = "inotify_rm_watch",
	[278] = "spu_run",
	[279] = "spu_create",
	[280] = "pselect6",
	[281] = "ppoll",
	[282] = "unshare",
	[283] = "splice",
	[284] = "tee",
	[285] = "vmsplice",
	[286] = "openat",
	[287] = "mkdirat",
	[288] = "mknodat",
	[289] = "fchownat",
	[290] = "futimesat",
	[291] = "fstatat64",
	[292] = "unlinkat",
	[293] = "renameat",
	[294] = "linkat",
	[295] = "symlinkat",
	[296] = "readlinkat",
	[297] = "fchmodat",
	[298] = "faccessat",
	[299] = "get_robust_list",
	[300] = "set_robust_list",
	[301] = "move_pages",
	[302] = "getcpu",
	[303] = "epoll_pwait",
	[304] = "utimensat",
	[305] = "signalfd",
	[306] = "timerfd_create",
	[307] = "eventfd",
	[308] = "sync_file_range2",
	[309] = "fallocate",
	[310] = "subpage_prot",
	[311] = "timerfd_settime",
	[312] = "timerfd_gettime",
	[313] = "signalfd4",
	[314] = "eventfd2",
	[315] = "epoll_create1",
	[316] = "dup3",
	[317] = "pipe2",
	[318] = "inotify_init1",
	[319] = "perf_event_open",
	[320] = "preadv",
	[321] = "pwritev",
	[322] = "rt_tgsigqueueinfo",
	[323] = "fanotify_init",
	[324] = "fanotify_mark",
	[325] = "prlimit64",
	[326] = "socket",
	[327] = "bind",
	[328] = "connect",
	[329] = "listen",
	[330] = "accept",
	[331] = "getsockname",
	[332] = "getpeername",
	[333] = "socketpair",
	[334] = "send",
	[335] = "sendto",
	[336] = "recv",
	[337] = "recvfrom",
	[338] = "shutdown",
	[339] = "setsockopt",
	[340] = "getsockopt",
	[341] = "sendmsg",
	[342] = "recvmsg",
	[343] = "recvmmsg",
	[344] = "accept4",
	[345] = "name_to_handle_at",
	[346] = "open_by_handle_at",
	[347] = "clock_adjtime",
	[348] = "syncfs",
	[349] = "sendmmsg",
	[350] = "setns",
	[351] = "process_vm_readv",
	[352] = "process_vm_writev",
	[353] = "finit_module",
	[354] = "kcmp",
	[355] = "sched_setattr",
	[356] = "sched_getattr",
	[357] = "renameat2",
	[358] = "seccomp",
	[359] = "getrandom",
	[360] = "memfd_create",
	[361] = "bpf",
	[362] = "execveat",
	[363] = "switch_endian",
	[364] = "userfaultfd",
	[365] = "membarrier",
	[378] = "mlock2",
	[379] = "copy_file_range",
	[380] = "preadv2",
	[381] = "pwritev2",
	[382] = "kexec_file_load",
	[383] = "statx",
	[384] = "pkey_alloc",
	[385] = "pkey_free",
	[386] = "pkey_mprotect",
	[387] = "rseq",
	[388] = "io_pgetevents",
	[393] = "semget",
	[394] = "semctl",
	[395] = "shmget",
	[396] = "shmctl",
	[397] = "shmat",
	[398] = "shmdt",
	[399] = "msgget",
	[400] = "msgsnd",
	[401] = "msgrcv",
	[402] = "msgctl",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_PPC[] = {
	140,	/* _llseek */
	142,	/* _newselect */
	149,	/* _sysctl */
	330,	/* accept */
	344,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	269,	/* add_key */
	124,	/* adjtimex */
	137,	/* afs_syscall */
	27,	/* alarm */
	134,	/* bdflush */
	327,	/* bind */
	361,	/* bpf */
	17,	/* break */
	45,	/* brk */
	451,	/* cachestat */
	183,	/* capget */
	184,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	181,	/* chown */
	61,	/* chroot */
	347,	/* clock_adjtime */
	405,	/* clock_adjtime64 */
	247,	/* clock_getres */
	406,	/* clock_getres_time64 */
	246,	/* clock_gettime */
	403,	/* clock_gettime64 */
	248,	/* clock_nanosleep */
	407,	/* clock_nanosleep_time64 */
	245,	/* clock_settime */
	404,	/* clock_settime64 */
	120,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	328,	/* connect */
	379,	/* copy_file_range */
	8,	/* creat */
	127,	/* create_module */
	129,	/* delete_module */
	41,	/* dup */
	63,	/* dup2 */
	316,	/* dup3 */
	236,	/* epoll_create */
	315,	/* epoll_create1 */
	237,	/* epoll_ctl */
	303,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	238,	/* epoll_wait */
	307,	/* eventfd */
	314,	/* eventfd2 */
	11,	/* execve */
	362,	/* execveat */
	1,	/* exit */
	234,	/* exit_group */
	298,	/* faccessat */
	439,	/* faccessat2 */
	233,	/* fadvise64 */
	254,	/* fadvise64_64 */
	309,	/* fallocate */
	323,	/* fanotify_init */
	324,	/* fanotify_mark */
	133,	/* fchdir */
	94,	/* fchmod */
	297,	/* fchmodat */
	452,	/* fchmodat2 */
	95,	/* fchown */
	289,	/* fchownat */
	55,	/* fcntl */
	204,	/* fcntl64 */
	148,	/* fdatasync */
	214,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	353,	/* finit_module */
	217,	/* flistxattr */
	143,	/* flock */
	2,	/* fork */
	220,	/* fremovexattr */
	431,	/* fsconfig */
	211,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	108,	/* fstat */
	197,	/* fstat64 */
	291,	/* fstatat64 */
	100,	/* fstatfs */
	253,	/* fstatfs64 */
	118,	/* fsync */
	35,	/* ftime */
	93,	/* ftruncate */
	194,	/* ftruncate64 */
	221,	/* futex */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	290,	/* futimesat */
	130,	/* get_kernel_syms */
	260,	/* get_mempolicy */
	299,	/* get_robust_list */
	302,	/* getcpu */
	182,	/* getcwd */
	141,	/* getdents */
	202,	/* getdents64 */
	50,	/* getegid */
	49,	/* geteuid */
	47,	/* getgid */
	80,	/* getgroups */
	105,	/* getitimer */
	332,	/* getpeername */
	132,	/* getpgid */
	65,	/* getpgrp */
	20,	/* getpid */
	187,	/* getpmsg */
	64,	/* getppid */
	96,	/* getpriority */
	359,	/* getrandom */
	170,	/* getresgid */
	165,	/* getresuid */
	76,	/* getrlimit */
	77,	/* getrusage */
	147,	/* getsid */
	331,	/* getsockname */
	340,	/* getsockopt */
	207,	/* gettid */
	78,	/* gettimeofday */
	24,	/* getuid */
	212,	/* getxattr */
	464,	/* getxattrat */
	32,	/* gtty */
	112,	/* idle */
	128,	/* init_module */
	276,	/* inotify_add_watch */
	275,	/* inotify_init */
	318,	/* inotify_init1 */
	277,	/* inotify_rm_watch */
	231,	/* io_cancel */
	228,	/* io_destroy */
	229,	/* io_getevents */
	388,	/* io_pgetevents */
	416,	/* io_pgetevents_time64 */
	227,	/* io_setup */
	230,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	101,	/* ioperm */
	110,	/* iopl */
	274,	/* ioprio_get */
	273,	/* ioprio_set */
	117,	/* ipc */
	354,	/* kcmp */
	382,	/* kexec_file_load */
	268,	/* kexec_load */
	271,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	213,	/* lgetxattr */
	9,	/* link */
	294,	/* linkat */
	329,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	215,	/* listxattr */
	465,	/* listxattrat */
	216,	/* llistxattr */
	53,	/* lock */
	235,	/* lookup_dcookie */
	219,	/* lremovexattr */
	19,	/* lseek */
	210,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	107,	/* lstat */
	196,	/* lstat64 */
	205,	/* madvise */
	453,	/* map_shadow_stack */
	259,	/* mbind */
	365,	/* membarrier */
	360,	/* memfd_create */
	258,	/* migrate_pages */
	206,	/* mincore */
	39,	/* mkdir */
	287,	/* mkdirat */
	14,	/* mknod */
	288,	/* mknodat */
	150,	/* mlock */
	378,	/* mlock2 */
	152,	/* mlockall */
	90,	/* mmap */
	192,	/* mmap2 */
	123,	/* modify_ldt */
	21,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	301,	/* move_pages */
	125,	/* mprotect */
	56,	/* mpx */
	267,	/* mq_getsetattr */
	266,	/* mq_notify */
	262,	/* mq_open */
	265,	/* mq_timedreceive */
	419,	/* mq_timedreceive_time64 */
	264,	/* mq_timedsend */
	418,	/* mq_timedsend_time64 */
	263,	/* mq_unlink */
	163,	/* mremap */
	462,	/* mseal */
	402,	/* msgctl */
	399,	/* msgget */
	401,	/* msgrcv */
	400,	/* msgsnd */
	144,	/* msync */
	201,	/* multiplexer */
	151,	/* munlock */
	153,	/* munlockall */
	91,	/* munmap */
	345,	/* name_to_handle_at */
	162,	/* nanosleep */
	168,	/* nfsservctl */
	34,	/* nice */
	28,	/* oldfstat */
	84,	/* oldlstat */
	59,	/* oldolduname */
	18,	/* oldstat */
	109,	/* olduname */
	5,	/* open */
	346,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	286,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	200,	/* pciconfig_iobase */
	198,	/* pciconfig_read */
	199,	/* pciconfig_write */
	319,	/* perf_event_open */
	136,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	317,	/* pipe2 */
	203,	/* pivot_root */
	384,	/* pkey_alloc */
	385,	/* pkey_free */
	386,	/* pkey_mprotect */
	167,	/* poll */
	281,	/* ppoll */
	414,	/* ppoll_time64 */
	171,	/* prctl */
	179,	/* pread64 */
	320,	/* preadv */
	380,	/* preadv2 */
	325,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	351,	/* process_vm_readv */
	352,	/* process_vm_writev */
	44,	/* prof */
	98,	/* profil */
	280,	/* pselect6 */
	413,	/* pselect6_time64 */
	26,	/* ptrace */
	188,	/* putpmsg */
	180,	/* pwrite64 */
	321,	/* pwritev */
	381,	/* pwritev2 */
	166,	/* query_module */
	131,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	191,	/* readahead */
	89,	/* readdir */
	85,	/* readlink */
	296,	/* readlinkat */
	145,	/* readv */
	88,	/* reboot */
	336,	/* recv */
	337,	/* recvfrom */
	343,	/* recvmmsg */
	417,	/* recvmmsg_time64 */
	342,	/* recvmsg */
	239,	/* remap_file_pages */
	218,	/* removexattr */
	466,	/* removexattrat */
	38,	/* rename */
	293,	/* renameat */
	357,	/* renameat2 */
	270,	/* request_key */
	0,	/* restart_syscall */
	40,	/* rmdir */
	387,	/* rseq */
	471,	/* rseq_slice_yield */
	173,	/* rt_sigaction */
	175,	/* rt_sigpending */
	174,	/* rt_sigprocmask */
	177,	/* rt_sigqueueinfo */
	172,	/* rt_sigreturn */
	178,	/* rt_sigsuspend */
	176,	/* rt_sigtimedwait */
	421,	/* rt_sigtimedwait_time64 */
	322,	/* rt_tgsigqueueinfo */
	255,	/* rtas */
	159,	/* sched_get_priority_max */
	160,	/* sched_get_priority_min */
	223,	/* sched_getaffinity */
	356,	/* sched_getattr */
	155,	/* sched_getparam */
	157,	/* sched_getscheduler */
	161,	/* sched_rr_get_interval */
	423,	/* sched_rr_get_interval_time64 */
	222,	/* sched_setaffinity */
	355,	/* sched_setattr */
	154,	/* sched_setparam */
	156,	/* sched_setscheduler */
	158,	/* sched_yield */
	358,	/* seccomp */
	82,	/* select */
	394,	/* semctl */
	393,	/* semget */
	420,	/* semtimedop_time64 */
	334,	/* send */
	186,	/* sendfile */
	226,	/* sendfile64 */
	349,	/* sendmmsg */
	341,	/* sendmsg */
	335,	/* sendto */
	261,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	300,	/* set_robust_list */
	232,	/* set_tid_address */
	121,	/* setdomainname */
	139,	/* setfsgid */
	138,	/* setfsuid */
	46,	/* setgid */
	81,	/* setgroups */
	74,	/* sethostname */
	104,	/* setitimer */
	350,	/* setns */
	57,	/* setpgid */
	97,	/* setpriority */
	71,	/* setregid */
	169,	/* setresgid */
	164,	/* setresuid */
	70,	/* setreuid */
	75,	/* setrlimit */
	66,	/* setsid */
	339,	/* setsockopt */
	79,	/* settimeofday */
	23,	/* setuid */
	209,	/* setxattr */
	463,	/* setxattrat */
	68,	/* sgetmask */
	397,	/* shmat */
	396,	/* shmctl */
	398,	/* shmdt */
	395,	/* shmget */
	338,	/* shutdown */
	67,	/* sigaction */
	185,	/* sigaltstack */
	48,	/* signal */
	305,	/* signalfd */
	313,	/* signalfd4 */
	73,	/* sigpending */
	126,	/* sigprocmask */
	119,	/* sigreturn */
	72,	/* sigsuspend */
	326,	/* socket */
	102,	/* socketcall */
	333,	/* socketpair */
	283,	/* splice */
	279,	/* spu_create */
	278,	/* spu_run */
	69,	/* ssetmask */
	106,	/* stat */
	195,	/* stat64 */
	99,	/* statfs */
	252,	/* statfs64 */
	457,	/* statmount */
	383,	/* statx */
	25,	/* stime */
	31,	/* stty */
	310,	/* subpage_prot */
	249,	/* swapcontext */
	115,	/* swapoff */
	87,	/* swapon */
	363,	/* switch_endian */
	83,	/* symlink */
	295,	/* symlinkat */
	36,	/* sync */
	308,	/* sync_file_range2 */
	348,	/* syncfs */
	256,	/* sys_debug_setcontext */
	135,	/* sysfs */
	116,	/* sysinfo */
	103,	/* syslog */
	284,	/* tee */
	250,	/* tgkill */
	13,	/* time */
	240,	/* timer_create */
	244,	/* timer_delete */
	243,	/* timer_getoverrun */
	242,	/* timer_gettime */
	408,	/* timer_gettime64 */
	241,	/* timer_settime */
	409,	/* timer_settime64 */
	306,	/* timerfd_create */
	312,	/* timerfd_gettime */
	410,	/* timerfd_gettime64 */
	311,	/* timerfd_settime */
	411,	/* timerfd_settime64 */
	43,	/* times */
	208,	/* tkill */
	92,	/* truncate */
	193,	/* truncate64 */
	225,	/* tuxcall */
	190,	/* ugetrlimit */
	58,	/* ulimit */
	60,	/* umask */
	22,	/* umount */
	52,	/* umount2 */
	122,	/* uname */
	10,	/* unlink */
	292,	/* unlinkat */
	282,	/* unshare */
	86,	/* uselib */
	364,	/* userfaultfd */
	62,	/* ustat */
	30,	/* utime */
	304,	/* utimensat */
	412,	/* utimensat_time64 */
	251,	/* utimes */
	189,	/* vfork */
	111,	/* vhangup */
	113,	/* vm86 */
	285,	/* vmsplice */
	114,	/* wait4 */
	272,	/* waitid */
	7,	/* waitpid */
	4,	/* write */
	146,	/* writev */
};
static const char *const syscall_num_to_name_EM_PPC64[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "waitpid",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execve",
	[12] = "chdir",
	[13] = "time",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[17] = "break",
	[18] = "oldstat",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "mount",
	[22] = "umount",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "stime",
	[26] = "ptrace",
	[27] = "alarm",
	[28] = "oldfstat",
	[29] = "pause",
	[30] = "utime",
	[31] = "stty",
	[32] = "gtty",
	[33] = "access",
	[34] = "nice",
	[35] = "ftime",
	[36] = "sync",
	[37] = "kill",
	[38] = "rename",
	[39] = "mkdir",
	[40] = "rmdir",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[44] = "prof",
	[45] = "brk",
	[46] = "setgid",
	[47] = "getgid",
	[48] = "signal",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[52] = "umount2",
	[53] = "lock",
	[54] = "ioctl",
	[55] = "fcntl",
	[56] = "mpx",
	[57] = "setpgid",
	[58] = "ulimit",
	[59] = "oldolduname",
	[60] = "umask",
	[61] = "chroot",
	[62] = "ustat",
	[63] = "dup2",
	[64] = "getppid",
	[65] = "getpgrp",
	[66] = "setsid",
	[67] = "sigaction",
	[68] = "sgetmask",
	[69] = "ssetmask",
	[70] = "setreuid",
	[71] = "setregid",
	[72] = "sigsuspend",
	[73] = "sigpending",
	[74] = "sethostname",
	[75] = "setrlimit",
	[76] = "getrlimit",
	[77] = "getrusage",
	[78] = "gettimeofday",
	[79] = "settimeofday",
	[80] = "getgroups",
	[81] = "setgroups",
	[82] = "select",
	[83] = "symlink",
	[84] = "oldlstat",
	[85] = "readlink",
	[86] = "uselib",
	[87] = "swapon",
	[88] = "reboot",
	[89] = "readdir",
	[90] = "mmap",
	[91] = "munmap",
	[92] = "truncate",
	[93] = "ftruncate",
	[94] = "fchmod",
	[95] = "fchown",
	[96] = "getpriority",
	[97] = "setpriority",
	[98] = "profil",
	[99] = "statfs",
	[100] = "fstatfs",
	[101] = "ioperm",
	[102] = "socketcall",
	[103] = "syslog",
	[104] = "setitimer",
	[105] = "getitimer",
	[106] = "stat",
	[107] = "lstat",
	[108] = "fstat",
	[109] = "olduname",
	[110] = "iopl",
	[111] = "vhangup",
	[112] = "idle",
	[113] = "vm86",
	[114] = "wait4",
	[115] = "swapoff",
	[116] = "sysinfo",
	[117] = "ipc",
	[118] = "fsync",
	[119] = "sigreturn",
	[120] = "clone",
	[121] = "setdomainname",
	[122] = "uname",
	[123] = "modify_ldt",
	[124] = "adjtimex",
	[125] = "mprotect",
	[126] = "sigprocmask",
	[127] = "create_module",
	[128] = "init_module",
	[129] = "delete_module",
	[130] = "get_kernel_syms",
	[131] = "quotactl",
	[132] = "getpgid",
	[133] = "fchdir",
	[134] = "bdflush",
	[135] = "sysfs",
	[136] = "personality",
	[137] = "afs_syscall",
	[138] = "setfsuid",
	[139] = "setfsgid",
	[140] = "_llseek",
	[141] = "getdents",
	[142] = "_newselect",
	[143] = "flock",
	[144] = "msync",
	[145] = "readv",
	[146] = "writev",
	[147] = "getsid",
	[148] = "fdatasync",
	[149] = "_sysctl",
	[150] = "mlock",
	[151] = "munlock",
	[152] = "mlockall",
	[153] = "munlockall",
	[154] = "sched_setparam",
	[155] = "sched_getparam",
	[156] = "sched_setscheduler",
	[157] = "sched_getscheduler",
	[158] = "sched_yield",
	[159] = "sched_get_priority_max",
	[160] = "sched_get_priority_min",
	[161] = "sched_rr_get_interval",
	[162] = "nanosleep",
	[163] = "mremap",
	[164] = "setresuid",
	[165] = "getresuid",
	[166] = "query_module",
	[167] = "poll",
	[168] = "nfsservctl",
	[169] = "setresgid",
	[170] = "getresgid",
	[171] = "prctl",
	[172] = "rt_sigreturn",
	[173] = "rt_sigaction",
	[174] = "rt_sigprocmask",
	[175] = "rt_sigpending",
	[176] = "rt_sigtimedwait",
	[177] = "rt_sigqueueinfo",
	[178] = "rt_sigsuspend",
	[179] = "pread64",
	[180] = "pwrite64",
	[181] = "chown",
	[182] = "getcwd",
	[183] = "capget",
	[184] = "capset",
	[185] = "sigaltstack",
	[186] = "sendfile",
	[187] = "getpmsg",
	[188] = "putpmsg",
	[189] = "vfork",
	[190] = "ugetrlimit",
	[191] = "readahead",
	[198] = "pciconfig_read",
	[199] = "pciconfig_write",
	[200] = "pciconfig_iobase",
	[201] = "multiplexer",
	[202] = "getdents64",
	[203] = "pivot_root",
	[205] = "madvise",
	[206] = "mincore",
	[207] = "gettid",
	[208] = "tkill",
	[209] = "setxattr",
	[210] = "lsetxattr",
	[211] = "fsetxattr",
	[212] = "getxattr",
	[213] = "lgetxattr",
	[214] = "fgetxattr",
	[215] = "listxattr",
	[216] = "llistxattr",
	[217] = "flistxattr",
	[218] = "removexattr",
	[219] = "lremovexattr",
	[220] = "fremovexattr",
	[221] = "futex",
	[222] = "sched_setaffinity",
	[223] = "sched_getaffinity",
	[225] = "tuxcall",
	[227] = "io_setup",
	[228] = "io_destroy",
	[229] = "io_getevents",
	[230] = "io_submit",
	[231] = "io_cancel",
	[232] = "set_tid_address",
	[233] = "fadvise64",
	[234] = "exit_group",
	[235] = "lookup_dcookie",
	[236] = "epoll_create",
	[237] = "epoll_ctl",
	[238] = "epoll_wait",
	[239] = "remap_file_pages",
	[240] = "timer_create",
	[241] = "timer_settime",
	[242] = "timer_gettime",
	[243] = "timer_getoverrun",
	[244] = "timer_delete",
	[245] = "clock_settime",
	[246] = "clock_gettime",
	[247] = "clock_getres",
	[248] = "clock_nanosleep",
	[249] = "swapcontext",
	[250] = "tgkill",
	[251] = "utimes",
	[252] = "statfs64",
	[253] = "fstatfs64",
	[255] = "rtas",
	[256] = "sys_debug_setcontext",
	[258] = "migrate_pages",
	[259] = "mbind",
	[260] = "get_mempolicy",
	[261] = "set_mempolicy",
	[262] = "mq_open",
	[263] = "mq_unlink",
	[264] = "mq_timedsend",
	[265] = "mq_timedreceive",
	[266] = "mq_notify",
	[267] = "mq_getsetattr",
	[268] = "kexec_load",
	[269] = "add_key",
	[270] = "request_key",
	[271] = "keyctl",
	[272] = "waitid",
	[273] = "ioprio_set",
	[274] = "ioprio_get",
	[275] = "inotify_init",
	[276] = "inotify_add_watch",
	[277] = "inotify_rm_watch",
	[278] = "spu_run",
	[279] = "spu_create",
	[280] = "pselect6",
	[281] = "ppoll",
	[282] = "unshare",
	[283] = "splice",
	[284] = "tee",
	[285] = "vmsplice",
	[286] = "openat",
	[287] = "mkdirat",
	[288] = "mknodat",
	[289] = "fchownat",
	[290] = "futimesat",
	[291] = "newfstatat",
	[292] = "unlinkat",
	[293] = "renameat",
	[294] = "linkat",
	[295] = "symlinkat",
	[296] = "readlinkat",
	[297] = "fchmodat",
	[298] = "faccessat",
	[299] = "get_robust_list",
	[300] = "set_robust_list",
	[301] = "move_pages",
	[302] = "getcpu",
	[303] = "epoll_pwait",
	[304] = "utimensat",
	[305] = "signalfd",
	[306] = "timerfd_create",
	[307] = "eventfd",
	[308] = "sync_file_range2",
	[309] = "fallocate",
	[310] = "subpage_prot",
	[311] = "timerfd_settime",
	[312] = "timerfd_gettime",
	[313] = "signalfd4",
	[314] = "eventfd2",
	[315] = "epoll_create1",
	[316] = "dup3",
	[317] = "pipe2",
	[318] = "inotify_init1",
	[319] = "perf_event_open",
	[320] = "preadv",
	[321] = "pwritev",
	[322] = "rt_tgsigqueueinfo",
	[323] = "fanotify_init",
	[324] = "fanotify_mark",
	[325] = "prlimit64",
	[326] = "socket",
	[327] = "bind",
	[328] = "connect",
	[329] = "listen",
	[330] = "accept",
	[331] = "getsockname",
	[332] = "getpeername",
	[333] = "socketpair",
	[334] = "send",
	[335] = "sendto",
	[336] = "recv",
	[337] = "recvfrom",
	[338] = "shutdown",
	[339] = "setsockopt",
	[340] = "getsockopt",
	[341] = "sendmsg",
	[342] = "recvmsg",
	[343] = "recvmmsg",
	[344] = "accept4",
	[345] = "name_to_handle_at",
	[346] = "open_by_handle_at",
	[347] = "clock_adjtime",
	[348] = "syncfs",
	[349] = "sendmmsg",
	[350] = "setns",
	[351] = "process_vm_readv",
	[352] = "process_vm_writev",
	[353] = "finit_module",
	[354] = "kcmp",
	[355] = "sched_setattr",
	[356] = "sched_getattr",
	[357] = "renameat2",
	[358] = "seccomp",
	[359] = "getrandom",
	[360] = "memfd_create",
	[361] = "bpf",
	[362] = "execveat",
	[363] = "switch_endian",
	[364] = "userfaultfd",
	[365] = "membarrier",
	[378] = "mlock2",
	[379] = "copy_file_range",
	[380] = "preadv2",
	[381] = "pwritev2",
	[382] = "kexec_file_load",
	[383] = "statx",
	[384] = "pkey_alloc",
	[385] = "pkey_free",
	[386] = "pkey_mprotect",
	[387] = "rseq",
	[388] = "io_pgetevents",
	[392] = "semtimedop",
	[393] = "semget",
	[394] = "semctl",
	[395] = "shmget",
	[396] = "shmctl",
	[397] = "shmat",
	[398] = "shmdt",
	[399] = "msgget",
	[400] = "msgsnd",
	[401] = "msgrcv",
	[402] = "msgctl",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_PPC64[] = {
	140,	/* _llseek */
	142,	/* _newselect */
	149,	/* _sysctl */
	330,	/* accept */
	344,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	269,	/* add_key */
	124,	/* adjtimex */
	137,	/* afs_syscall */
	27,	/* alarm */
	134,	/* bdflush */
	327,	/* bind */
	361,	/* bpf */
	17,	/* break */
	45,	/* brk */
	451,	/* cachestat */
	183,	/* capget */
	184,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	181,	/* chown */
	61,	/* chroot */
	347,	/* clock_adjtime */
	247,	/* clock_getres */
	246,	/* clock_gettime */
	248,	/* clock_nanosleep */
	245,	/* clock_settime */
	120,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	328,	/* connect */
	379,	/* copy_file_range */
	8,	/* creat */
	127,	/* create_module */
	129,	/* delete_module */
	41,	/* dup */
	63,	/* dup2 */
	316,	/* dup3 */
	236,	/* epoll_create */
	315,	/* epoll_create1 */
	237,	/* epoll_ctl */
	303,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	238,	/* epoll_wait */
	307,	/* eventfd */
	314,	/* eventfd2 */
	11,	/* execve */
	362,	/* execveat */
	1,	/* exit */
	234,	/* exit_group */
	298,	/* faccessat */
	439,	/* faccessat2 */
	233,	/* fadvise64 */
	309,	/* fallocate */
	323,	/* fanotify_init */
	324,	/* fanotify_mark */
	133,	/* fchdir */
	94,	/* fchmod */
	297,	/* fchmodat */
	452,	/* fchmodat2 */
	95,	/* fchown */
	289,	/* fchownat */
	55,	/* fcntl */
	148,	/* fdatasync */
	214,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	353,	/* finit_module */
	217,	/* flistxattr */
	143,	/* flock */
	2,	/* fork */
	220,	/* fremovexattr */
	431,	/* fsconfig */
	211,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	108,	/* fstat */
	100,	/* fstatfs */
	253,	/* fstatfs64 */
	118,	/* fsync */
	35,	/* ftime */
	93,	/* ftruncate */
	221,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	290,	/* futimesat */
	130,	/* get_kernel_syms */
	260,	/* get_mempolicy */
	299,	/* get_robust_list */
	302,	/* getcpu */
	182,	/* getcwd */
	141,	/* getdents */
	202,	/* getdents64 */
	50,	/* getegid */
	49,	/* geteuid */
	47,	/* getgid */
	80,	/* getgroups */
	105,	/* getitimer */
	332,	/* getpeername */
	132,	/* getpgid */
	65,	/* getpgrp */
	20,	/* getpid */
	187,	/* getpmsg */
	64,	/* getppid */
	96,	/* getpriority */
	359,	/* getrandom */
	170,	/* getresgid */
	165,	/* getresuid */
	76,	/* getrlimit */
	77,	/* getrusage */
	147,	/* getsid */
	331,	/* getsockname */
	340,	/* getsockopt */
	207,	/* gettid */
	78,	/* gettimeofday */
	24,	/* getuid */
	212,	/* getxattr */
	464,	/* getxattrat */
	32,	/* gtty */
	112,	/* idle */
	128,	/* init_module */
	276,	/* inotify_add_watch */
	275,	/* inotify_init */
	318,	/* inotify_init1 */
	277,	/* inotify_rm_watch */
	231,	/* io_cancel */
	228,	/* io_destroy */
	229,	/* io_getevents */
	388,	/* io_pgetevents */
	227,	/* io_setup */
	230,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	101,	/* ioperm */
	110,	/* iopl */
	274,	/* ioprio_get */
	273,	/* ioprio_set */
	117,	/* ipc */
	354,	/* kcmp */
	382,	/* kexec_file_load */
	268,	/* kexec_load */
	271,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	213,	/* lgetxattr */
	9,	/* link */
	294,	/* linkat */
	329,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	215,	/* listxattr */
	465,	/* listxattrat */
	216,	/* llistxattr */
	53,	/* lock */
	235,	/* lookup_dcookie */
	219,	/* lremovexattr */
	19,	/* lseek */
	210,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	107,	/* lstat */
	205,	/* madvise */
	453,	/* map_shadow_stack */
	259,	/* mbind */
	365,	/* membarrier */
	360,	/* memfd_create */
	258,	/* migrate_pages */
	206,	/* mincore */
	39,	/* mkdir */
	287,	/* mkdirat */
	14,	/* mknod */
	288,	/* mknodat */
	150,	/* mlock */
	378,	/* mlock2 */
	152,	/* mlockall */
	90,	/* mmap */
	123,	/* modify_ldt */
	21,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	301,	/* move_pages */
	125,	/* mprotect */
	56,	/* mpx */
	267,	/* mq_getsetattr */
	266,	/* mq_notify */
	262,	/* mq_open */
	265,	/* mq_timedreceive */
	264,	/* mq_timedsend */
	263,	/* mq_unlink */
	163,	/* mremap */
	462,	/* mseal */
	402,	/* msgctl */
	399,	/* msgget */
	401,	/* msgrcv */
	400,	/* msgsnd */
	144,	/* msync */
	201,	/* multiplexer */
	151,	/* munlock */
	153,	/* munlockall */
	91,	/* munmap */
	345,	/* name_to_handle_at */
	162,	/* nanosleep */
	291,	/* newfstatat */
	168,	/* nfsservctl */
	34,	/* nice */
	28,	/* oldfstat */
	84,	/* oldlstat */
	59,	/* oldolduname */
	18,	/* oldstat */
	109,	/* olduname */
	5,	/* open */
	346,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	286,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	200,	/* pciconfig_iobase */
	198,	/* pciconfig_read */
	199,	/* pciconfig_write */
	319,	/* perf_event_open */
	136,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	317,	/* pipe2 */
	203,	/* pivot_root */
	384,	/* pkey_alloc */
	385,	/* pkey_free */
	386,	/* pkey_mprotect */
	167,	/* poll */
	281,	/* ppoll */
	171,	/* prctl */
	179,	/* pread64 */
	320,	/* preadv */
	380,	/* preadv2 */
	325,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	351,	/* process_vm_readv */
	352,	/* process_vm_writev */
	44,	/* prof */
	98,	/* profil */
	280,	/* pselect6 */
	26,	/* ptrace */
	188,	/* putpmsg */
	180,	/* pwrite64 */
	321,	/* pwritev */
	381,	/* pwritev2 */
	166,	/* query_module */
	131,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	191,	/* readahead */
	89,	/* readdir */
	85,	/* readlink */
	296,	/* readlinkat */
	145,	/* readv */
	88,	/* reboot */
	336,	/* recv */
	337,	/* recvfrom */
	343,	/* recvmmsg */
	342,	/* recvmsg */
	239,	/* remap_file_pages */
	218,	/* removexattr */
	466,	/* removexattrat */
	38,	/* rename */
	293,	/* renameat */
	357,	/* renameat2 */
	270,	/* request_key */
	0,	/* restart_syscall */
	40,	/* rmdir */
	387,	/* rseq */
	471,	/* rseq_slice_yield */
	173,	/* rt_sigaction */
	175,	/* rt_sigpending */
	174,	/* rt_sigprocmask */
	177,	/* rt_sigqueueinfo */
	172,	/* rt_sigreturn */
	178,	/* rt_sigsuspend */
	176,	/* rt_sigtimedwait */
	322,	/* rt_tgsigqueueinfo */
	255,	/* rtas */
	159,	/* sched_get_priority_max */
	160,	/* sched_get_priority_min */
	223,	/* sched_getaffinity */
	356,	/* sched_getattr */
	155,	/* sched_getparam */
	157,	/* sched_getscheduler */
	161,	/* sched_rr_get_interval */
	222,	/* sched_setaffinity */
	355,	/* sched_setattr */
	154,	/* sched_setparam */
	156,	/* sched_setscheduler */
	158,	/* sched_yield */
	358,	/* seccomp */
	82,	/* select */
	394,	/* semctl */
	393,	/* semget */
	392,	/* semtimedop */
	334,	/* send */
	186,	/* sendfile */
	349,	/* sendmmsg */
	341,	/* sendmsg */
	335,	/* sendto */
	261,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	300,	/* set_robust_list */
	232,	/* set_tid_address */
	121,	/* setdomainname */
	139,	/* setfsgid */
	138,	/* setfsuid */
	46,	/* setgid */
	81,	/* setgroups */
	74,	/* sethostname */
	104,	/* setitimer */
	350,	/* setns */
	57,	/* setpgid */
	97,	/* setpriority */
	71,	/* setregid */
	169,	/* setresgid */
	164,	/* setresuid */
	70,	/* setreuid */
	75,	/* setrlimit */
	66,	/* setsid */
	339,	/* setsockopt */
	79,	/* settimeofday */
	23,	/* setuid */
	209,	/* setxattr */
	463,	/* setxattrat */
	68,	/* sgetmask */
	397,	/* shmat */
	396,	/* shmctl */
	398,	/* shmdt */
	395,	/* shmget */
	338,	/* shutdown */
	67,	/* sigaction */
	185,	/* sigaltstack */
	48,	/* signal */
	305,	/* signalfd */
	313,	/* signalfd4 */
	73,	/* sigpending */
	126,	/* sigprocmask */
	119,	/* sigreturn */
	72,	/* sigsuspend */
	326,	/* socket */
	102,	/* socketcall */
	333,	/* socketpair */
	283,	/* splice */
	279,	/* spu_create */
	278,	/* spu_run */
	69,	/* ssetmask */
	106,	/* stat */
	99,	/* statfs */
	252,	/* statfs64 */
	457,	/* statmount */
	383,	/* statx */
	25,	/* stime */
	31,	/* stty */
	310,	/* subpage_prot */
	249,	/* swapcontext */
	115,	/* swapoff */
	87,	/* swapon */
	363,	/* switch_endian */
	83,	/* symlink */
	295,	/* symlinkat */
	36,	/* sync */
	308,	/* sync_file_range2 */
	348,	/* syncfs */
	256,	/* sys_debug_setcontext */
	135,	/* sysfs */
	116,	/* sysinfo */
	103,	/* syslog */
	284,	/* tee */
	250,	/* tgkill */
	13,	/* time */
	240,	/* timer_create */
	244,	/* timer_delete */
	243,	/* timer_getoverrun */
	242,	/* timer_gettime */
	241,	/* timer_settime */
	306,	/* timerfd_create */
	312,	/* timerfd_gettime */
	311,	/* timerfd_settime */
	43,	/* times */
	208,	/* tkill */
	92,	/* truncate */
	225,	/* tuxcall */
	190,	/* ugetrlimit */
	58,	/* ulimit */
	60,	/* umask */
	22,	/* umount */
	52,	/* umount2 */
	122,	/* uname */
	10,	/* unlink */
	292,	/* unlinkat */
	282,	/* unshare */
	86,	/* uselib */
	364,	/* userfaultfd */
	62,	/* ustat */
	30,	/* utime */
	304,	/* utimensat */
	251,	/* utimes */
	189,	/* vfork */
	111,	/* vhangup */
	113,	/* vm86 */
	285,	/* vmsplice */
	114,	/* wait4 */
	272,	/* waitid */
	7,	/* waitpid */
	4,	/* write */
	146,	/* writev */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__powerpc__) || defined(__powerpc64__)

#if defined(ALL_SYSCALLTBL) || defined(__riscv)
#if __BITS_PER_LONG != 64
static const char *const syscall_num_to_name_EM_RISCV[] = {
	[0] = "io_setup",
	[1] = "io_destroy",
	[2] = "io_submit",
	[3] = "io_cancel",
	[5] = "setxattr",
	[6] = "lsetxattr",
	[7] = "fsetxattr",
	[8] = "getxattr",
	[9] = "lgetxattr",
	[10] = "fgetxattr",
	[11] = "listxattr",
	[12] = "llistxattr",
	[13] = "flistxattr",
	[14] = "removexattr",
	[15] = "lremovexattr",
	[16] = "fremovexattr",
	[17] = "getcwd",
	[18] = "lookup_dcookie",
	[19] = "eventfd2",
	[20] = "epoll_create1",
	[21] = "epoll_ctl",
	[22] = "epoll_pwait",
	[23] = "dup",
	[24] = "dup3",
	[25] = "fcntl64",
	[26] = "inotify_init1",
	[27] = "inotify_add_watch",
	[28] = "inotify_rm_watch",
	[29] = "ioctl",
	[30] = "ioprio_set",
	[31] = "ioprio_get",
	[32] = "flock",
	[33] = "mknodat",
	[34] = "mkdirat",
	[35] = "unlinkat",
	[36] = "symlinkat",
	[37] = "linkat",
	[39] = "umount2",
	[40] = "mount",
	[41] = "pivot_root",
	[42] = "nfsservctl",
	[43] = "statfs64",
	[44] = "fstatfs64",
	[45] = "truncate64",
	[46] = "ftruncate64",
	[47] = "fallocate",
	[48] = "faccessat",
	[49] = "chdir",
	[50] = "fchdir",
	[51] = "chroot",
	[52] = "fchmod",
	[53] = "fchmodat",
	[54] = "fchownat",
	[55] = "fchown",
	[56] = "openat",
	[57] = "close",
	[58] = "vhangup",
	[59] = "pipe2",
	[60] = "quotactl",
	[61] = "getdents64",
	[62] = "llseek",
	[63] = "read",
	[64] = "write",
	[65] = "readv",
	[66] = "writev",
	[67] = "pread64",
	[68] = "pwrite64",
	[69] = "preadv",
	[70] = "pwritev",
	[71] = "sendfile64",
	[74] = "signalfd4",
	[75] = "vmsplice",
	[76] = "splice",
	[77] = "tee",
	[78] = "readlinkat",
	[81] = "sync",
	[82] = "fsync",
	[83] = "fdatasync",
	[84] = "sync_file_range",
	[85] = "timerfd_create",
	[89] = "acct",
	[90] = "capget",
	[91] = "capset",
	[92] = "personality",
	[93] = "exit",
	[94] = "exit_group",
	[95] = "waitid",
	[96] = "set_tid_address",
	[97] = "unshare",
	[99] = "set_robust_list",
	[100] = "get_robust_list",
	[102] = "getitimer",
	[103] = "setitimer",
	[104] = "kexec_load",
	[105] = "init_module",
	[106] = "delete_module",
	[107] = "timer_create",
	[109] = "timer_getoverrun",
	[111] = "timer_delete",
	[116] = "syslog",
	[117] = "ptrace",
	[118] = "sched_setparam",
	[119] = "sched_setscheduler",
	[120] = "sched_getscheduler",
	[121] = "sched_getparam",
	[122] = "sched_setaffinity",
	[123] = "sched_getaffinity",
	[124] = "sched_yield",
	[125] = "sched_get_priority_max",
	[126] = "sched_get_priority_min",
	[128] = "restart_syscall",
	[129] = "kill",
	[130] = "tkill",
	[131] = "tgkill",
	[132] = "sigaltstack",
	[133] = "rt_sigsuspend",
	[134] = "rt_sigaction",
	[135] = "rt_sigprocmask",
	[136] = "rt_sigpending",
	[138] = "rt_sigqueueinfo",
	[139] = "rt_sigreturn",
	[140] = "setpriority",
	[141] = "getpriority",
	[142] = "reboot",
	[143] = "setregid",
	[144] = "setgid",
	[145] = "setreuid",
	[146] = "setuid",
	[147] = "setresuid",
	[148] = "getresuid",
	[149] = "setresgid",
	[150] = "getresgid",
	[151] = "setfsuid",
	[152] = "setfsgid",
	[153] = "times",
	[154] = "setpgid",
	[155] = "getpgid",
	[156] = "getsid",
	[157] = "setsid",
	[158] = "getgroups",
	[159] = "setgroups",
	[160] = "uname",
	[161] = "sethostname",
	[162] = "setdomainname",
	[165] = "getrusage",
	[166] = "umask",
	[167] = "prctl",
	[168] = "getcpu",
	[172] = "getpid",
	[173] = "getppid",
	[174] = "getuid",
	[175] = "geteuid",
	[176] = "getgid",
	[177] = "getegid",
	[178] = "gettid",
	[179] = "sysinfo",
	[180] = "mq_open",
	[181] = "mq_unlink",
	[184] = "mq_notify",
	[185] = "mq_getsetattr",
	[186] = "msgget",
	[187] = "msgctl",
	[188] = "msgrcv",
	[189] = "msgsnd",
	[190] = "semget",
	[191] = "semctl",
	[193] = "semop",
	[194] = "shmget",
	[195] = "shmctl",
	[196] = "shmat",
	[197] = "shmdt",
	[198] = "socket",
	[199] = "socketpair",
	[200] = "bind",
	[201] = "listen",
	[202] = "accept",
	[203] = "connect",
	[204] = "getsockname",
	[205] = "getpeername",
	[206] = "sendto",
	[207] = "recvfrom",
	[208] = "setsockopt",
	[209] = "getsockopt",
	[210] = "shutdown",
	[211] = "sendmsg",
	[212] = "recvmsg",
	[213] = "readahead",
	[214] = "brk",
	[215] = "munmap",
	[216] = "mremap",
	[217] = "add_key",
	[218] = "request_key",
	[219] = "keyctl",
	[220] = "clone",
	[221] = "execve",
	[222] = "mmap2",
	[223] = "fadvise64_64",
	[224] = "swapon",
	[225] = "swapoff",
	[226] = "mprotect",
	[227] = "msync",
	[228] = "mlock",
	[229] = "munlock",
	[230] = "mlockall",
	[231] = "munlockall",
	[232] = "mincore",
	[233] = "madvise",
	[234] = "remap_file_pages",
	[235] = "mbind",
	[236] = "get_mempolicy",
	[237] = "set_mempolicy",
	[238] = "migrate_pages",
	[239] = "move_pages",
	[240] = "rt_tgsigqueueinfo",
	[241] = "perf_event_open",
	[242] = "accept4",
	[258] = "riscv_hwprobe",
	[259] = "riscv_flush_icache",
	[261] = "prlimit64",
	[262] = "fanotify_init",
	[263] = "fanotify_mark",
	[264] = "name_to_handle_at",
	[265] = "open_by_handle_at",
	[267] = "syncfs",
	[268] = "setns",
	[269] = "sendmmsg",
	[270] = "process_vm_readv",
	[271] = "process_vm_writev",
	[272] = "kcmp",
	[273] = "finit_module",
	[274] = "sched_setattr",
	[275] = "sched_getattr",
	[276] = "renameat2",
	[277] = "seccomp",
	[278] = "getrandom",
	[279] = "memfd_create",
	[280] = "bpf",
	[281] = "execveat",
	[282] = "userfaultfd",
	[283] = "membarrier",
	[284] = "mlock2",
	[285] = "copy_file_range",
	[286] = "preadv2",
	[287] = "pwritev2",
	[288] = "pkey_mprotect",
	[289] = "pkey_alloc",
	[290] = "pkey_free",
	[291] = "statx",
	[293] = "rseq",
	[294] = "kexec_file_load",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[447] = "memfd_secret",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_RISCV[] = {
	202,	/* accept */
	242,	/* accept4 */
	89,	/* acct */
	217,	/* add_key */
	200,	/* bind */
	280,	/* bpf */
	214,	/* brk */
	451,	/* cachestat */
	90,	/* capget */
	91,	/* capset */
	49,	/* chdir */
	51,	/* chroot */
	405,	/* clock_adjtime64 */
	406,	/* clock_getres_time64 */
	403,	/* clock_gettime64 */
	407,	/* clock_nanosleep_time64 */
	404,	/* clock_settime64 */
	220,	/* clone */
	435,	/* clone3 */
	57,	/* close */
	436,	/* close_range */
	203,	/* connect */
	285,	/* copy_file_range */
	106,	/* delete_module */
	23,	/* dup */
	24,	/* dup3 */
	20,	/* epoll_create1 */
	21,	/* epoll_ctl */
	22,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	19,	/* eventfd2 */
	221,	/* execve */
	281,	/* execveat */
	93,	/* exit */
	94,	/* exit_group */
	48,	/* faccessat */
	439,	/* faccessat2 */
	223,	/* fadvise64_64 */
	47,	/* fallocate */
	262,	/* fanotify_init */
	263,	/* fanotify_mark */
	50,	/* fchdir */
	52,	/* fchmod */
	53,	/* fchmodat */
	452,	/* fchmodat2 */
	55,	/* fchown */
	54,	/* fchownat */
	25,	/* fcntl64 */
	83,	/* fdatasync */
	10,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	273,	/* finit_module */
	13,	/* flistxattr */
	32,	/* flock */
	16,	/* fremovexattr */
	431,	/* fsconfig */
	7,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	44,	/* fstatfs64 */
	82,	/* fsync */
	46,	/* ftruncate64 */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	236,	/* get_mempolicy */
	100,	/* get_robust_list */
	168,	/* getcpu */
	17,	/* getcwd */
	61,	/* getdents64 */
	177,	/* getegid */
	175,	/* geteuid */
	176,	/* getgid */
	158,	/* getgroups */
	102,	/* getitimer */
	205,	/* getpeername */
	155,	/* getpgid */
	172,	/* getpid */
	173,	/* getppid */
	141,	/* getpriority */
	278,	/* getrandom */
	150,	/* getresgid */
	148,	/* getresuid */
	165,	/* getrusage */
	156,	/* getsid */
	204,	/* getsockname */
	209,	/* getsockopt */
	178,	/* gettid */
	174,	/* getuid */
	8,	/* getxattr */
	464,	/* getxattrat */
	105,	/* init_module */
	27,	/* inotify_add_watch */
	26,	/* inotify_init1 */
	28,	/* inotify_rm_watch */
	3,	/* io_cancel */
	1,	/* io_destroy */
	416,	/* io_pgetevents_time64 */
	0,	/* io_setup */
	2,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	29,	/* ioctl */
	31,	/* ioprio_get */
	30,	/* ioprio_set */
	272,	/* kcmp */
	294,	/* kexec_file_load */
	104,	/* kexec_load */
	219,	/* keyctl */
	129,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	9,	/* lgetxattr */
	37,	/* linkat */
	201,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	11,	/* listxattr */
	465,	/* listxattrat */
	12,	/* llistxattr */
	62,	/* llseek */
	18,	/* lookup_dcookie */
	15,	/* lremovexattr */
	6,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	233,	/* madvise */
	453,	/* map_shadow_stack */
	235,	/* mbind */
	283,	/* membarrier */
	279,	/* memfd_create */
	447,	/* memfd_secret */
	238,	/* migrate_pages */
	232,	/* mincore */
	34,	/* mkdirat */
	33,	/* mknodat */
	228,	/* mlock */
	284,	/* mlock2 */
	230,	/* mlockall */
	222,	/* mmap2 */
	40,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	239,	/* move_pages */
	226,	/* mprotect */
	185,	/* mq_getsetattr */
	184,	/* mq_notify */
	180,	/* mq_open */
	419,	/* mq_timedreceive_time64 */
	418,	/* mq_timedsend_time64 */
	181,	/* mq_unlink */
	216,	/* mremap */
	462,	/* mseal */
	187,	/* msgctl */
	186,	/* msgget */
	188,	/* msgrcv */
	189,	/* msgsnd */
	227,	/* msync */
	229,	/* munlock */
	231,	/* munlockall */
	215,	/* munmap */
	264,	/* name_to_handle_at */
	42,	/* nfsservctl */
	265,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	56,	/* openat */
	437,	/* openat2 */
	241,	/* perf_event_open */
	92,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	59,	/* pipe2 */
	41,	/* pivot_root */
	289,	/* pkey_alloc */
	290,	/* pkey_free */
	288,	/* pkey_mprotect */
	414,	/* ppoll_time64 */
	167,	/* prctl */
	67,	/* pread64 */
	69,	/* preadv */
	286,	/* preadv2 */
	261,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	270,	/* process_vm_readv */
	271,	/* process_vm_writev */
	413,	/* pselect6_time64 */
	117,	/* ptrace */
	68,	/* pwrite64 */
	70,	/* pwritev */
	287,	/* pwritev2 */
	60,	/* quotactl */
	443,	/* quotactl_fd */
	63,	/* read */
	213,	/* readahead */
	78,	/* readlinkat */
	65,	/* readv */
	142,	/* reboot */
	207,	/* recvfrom */
	417,	/* recvmmsg_time64 */
	212,	/* recvmsg */
	234,	/* remap_file_pages */
	14,	/* removexattr */
	466,	/* removexattrat */
	276,	/* renameat2 */
	218,	/* request_key */
	128,	/* restart_syscall */
	259,	/* riscv_flush_icache */
	258,	/* riscv_hwprobe */
	293,	/* rseq */
	471,	/* rseq_slice_yield */
	134,	/* rt_sigaction */
	136,	/* rt_sigpending */
	135,	/* rt_sigprocmask */
	138,	/* rt_sigqueueinfo */
	139,	/* rt_sigreturn */
	133,	/* rt_sigsuspend */
	421,	/* rt_sigtimedwait_time64 */
	240,	/* rt_tgsigqueueinfo */
	125,	/* sched_get_priority_max */
	126,	/* sched_get_priority_min */
	123,	/* sched_getaffinity */
	275,	/* sched_getattr */
	121,	/* sched_getparam */
	120,	/* sched_getscheduler */
	423,	/* sched_rr_get_interval_time64 */
	122,	/* sched_setaffinity */
	274,	/* sched_setattr */
	118,	/* sched_setparam */
	119,	/* sched_setscheduler */
	124,	/* sched_yield */
	277,	/* seccomp */
	191,	/* semctl */
	190,	/* semget */
	193,	/* semop */
	420,	/* semtimedop_time64 */
	71,	/* sendfile64 */
	269,	/* sendmmsg */
	211,	/* sendmsg */
	206,	/* sendto */
	237,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	99,	/* set_robust_list */
	96,	/* set_tid_address */
	162,	/* setdomainname */
	152,	/* setfsgid */
	151,	/* setfsuid */
	144,	/* setgid */
	159,	/* setgroups */
	161,	/* sethostname */
	103,	/* setitimer */
	268,	/* setns */
	154,	/* setpgid */
	140,	/* setpriority */
	143,	/* setregid */
	149,	/* setresgid */
	147,	/* setresuid */
	145,	/* setreuid */
	157,	/* setsid */
	208,	/* setsockopt */
	146,	/* setuid */
	5,	/* setxattr */
	463,	/* setxattrat */
	196,	/* shmat */
	195,	/* shmctl */
	197,	/* shmdt */
	194,	/* shmget */
	210,	/* shutdown */
	132,	/* sigaltstack */
	74,	/* signalfd4 */
	198,	/* socket */
	199,	/* socketpair */
	76,	/* splice */
	43,	/* statfs64 */
	457,	/* statmount */
	291,	/* statx */
	225,	/* swapoff */
	224,	/* swapon */
	36,	/* symlinkat */
	81,	/* sync */
	84,	/* sync_file_range */
	267,	/* syncfs */
	179,	/* sysinfo */
	116,	/* syslog */
	77,	/* tee */
	131,	/* tgkill */
	107,	/* timer_create */
	111,	/* timer_delete */
	109,	/* timer_getoverrun */
	408,	/* timer_gettime64 */
	409,	/* timer_settime64 */
	85,	/* timerfd_create */
	410,	/* timerfd_gettime64 */
	411,	/* timerfd_settime64 */
	153,	/* times */
	130,	/* tkill */
	45,	/* truncate64 */
	166,	/* umask */
	39,	/* umount2 */
	160,	/* uname */
	35,	/* unlinkat */
	97,	/* unshare */
	282,	/* userfaultfd */
	412,	/* utimensat_time64 */
	58,	/* vhangup */
	75,	/* vmsplice */
	95,	/* waitid */
	64,	/* write */
	66,	/* writev */
};
#else
static const char *const syscall_num_to_name_EM_RISCV[] = {
	[0] = "io_setup",
	[1] = "io_destroy",
	[2] = "io_submit",
	[3] = "io_cancel",
	[4] = "io_getevents",
	[5] = "setxattr",
	[6] = "lsetxattr",
	[7] = "fsetxattr",
	[8] = "getxattr",
	[9] = "lgetxattr",
	[10] = "fgetxattr",
	[11] = "listxattr",
	[12] = "llistxattr",
	[13] = "flistxattr",
	[14] = "removexattr",
	[15] = "lremovexattr",
	[16] = "fremovexattr",
	[17] = "getcwd",
	[18] = "lookup_dcookie",
	[19] = "eventfd2",
	[20] = "epoll_create1",
	[21] = "epoll_ctl",
	[22] = "epoll_pwait",
	[23] = "dup",
	[24] = "dup3",
	[25] = "fcntl",
	[26] = "inotify_init1",
	[27] = "inotify_add_watch",
	[28] = "inotify_rm_watch",
	[29] = "ioctl",
	[30] = "ioprio_set",
	[31] = "ioprio_get",
	[32] = "flock",
	[33] = "mknodat",
	[34] = "mkdirat",
	[35] = "unlinkat",
	[36] = "symlinkat",
	[37] = "linkat",
	[39] = "umount2",
	[40] = "mount",
	[41] = "pivot_root",
	[42] = "nfsservctl",
	[43] = "statfs",
	[44] = "fstatfs",
	[45] = "truncate",
	[46] = "ftruncate",
	[47] = "fallocate",
	[48] = "faccessat",
	[49] = "chdir",
	[50] = "fchdir",
	[51] = "chroot",
	[52] = "fchmod",
	[53] = "fchmodat",
	[54] = "fchownat",
	[55] = "fchown",
	[56] = "openat",
	[57] = "close",
	[58] = "vhangup",
	[59] = "pipe2",
	[60] = "quotactl",
	[61] = "getdents64",
	[62] = "lseek",
	[63] = "read",
	[64] = "write",
	[65] = "readv",
	[66] = "writev",
	[67] = "pread64",
	[68] = "pwrite64",
	[69] = "preadv",
	[70] = "pwritev",
	[71] = "sendfile",
	[72] = "pselect6",
	[73] = "ppoll",
	[74] = "signalfd4",
	[75] = "vmsplice",
	[76] = "splice",
	[77] = "tee",
	[78] = "readlinkat",
	[79] = "newfstatat",
	[80] = "fstat",
	[81] = "sync",
	[82] = "fsync",
	[83] = "fdatasync",
	[84] = "sync_file_range",
	[85] = "timerfd_create",
	[86] = "timerfd_settime",
	[87] = "timerfd_gettime",
	[88] = "utimensat",
	[89] = "acct",
	[90] = "capget",
	[91] = "capset",
	[92] = "personality",
	[93] = "exit",
	[94] = "exit_group",
	[95] = "waitid",
	[96] = "set_tid_address",
	[97] = "unshare",
	[98] = "futex",
	[99] = "set_robust_list",
	[100] = "get_robust_list",
	[101] = "nanosleep",
	[102] = "getitimer",
	[103] = "setitimer",
	[104] = "kexec_load",
	[105] = "init_module",
	[106] = "delete_module",
	[107] = "timer_create",
	[108] = "timer_gettime",
	[109] = "timer_getoverrun",
	[110] = "timer_settime",
	[111] = "timer_delete",
	[112] = "clock_settime",
	[113] = "clock_gettime",
	[114] = "clock_getres",
	[115] = "clock_nanosleep",
	[116] = "syslog",
	[117] = "ptrace",
	[118] = "sched_setparam",
	[119] = "sched_setscheduler",
	[120] = "sched_getscheduler",
	[121] = "sched_getparam",
	[122] = "sched_setaffinity",
	[123] = "sched_getaffinity",
	[124] = "sched_yield",
	[125] = "sched_get_priority_max",
	[126] = "sched_get_priority_min",
	[127] = "sched_rr_get_interval",
	[128] = "restart_syscall",
	[129] = "kill",
	[130] = "tkill",
	[131] = "tgkill",
	[132] = "sigaltstack",
	[133] = "rt_sigsuspend",
	[134] = "rt_sigaction",
	[135] = "rt_sigprocmask",
	[136] = "rt_sigpending",
	[137] = "rt_sigtimedwait",
	[138] = "rt_sigqueueinfo",
	[139] = "rt_sigreturn",
	[140] = "setpriority",
	[141] = "getpriority",
	[142] = "reboot",
	[143] = "setregid",
	[144] = "setgid",
	[145] = "setreuid",
	[146] = "setuid",
	[147] = "setresuid",
	[148] = "getresuid",
	[149] = "setresgid",
	[150] = "getresgid",
	[151] = "setfsuid",
	[152] = "setfsgid",
	[153] = "times",
	[154] = "setpgid",
	[155] = "getpgid",
	[156] = "getsid",
	[157] = "setsid",
	[158] = "getgroups",
	[159] = "setgroups",
	[160] = "uname",
	[161] = "sethostname",
	[162] = "setdomainname",
	[163] = "getrlimit",
	[164] = "setrlimit",
	[165] = "getrusage",
	[166] = "umask",
	[167] = "prctl",
	[168] = "getcpu",
	[169] = "gettimeofday",
	[170] = "settimeofday",
	[171] = "adjtimex",
	[172] = "getpid",
	[173] = "getppid",
	[174] = "getuid",
	[175] = "geteuid",
	[176] = "getgid",
	[177] = "getegid",
	[178] = "gettid",
	[179] = "sysinfo",
	[180] = "mq_open",
	[181] = "mq_unlink",
	[182] = "mq_timedsend",
	[183] = "mq_timedreceive",
	[184] = "mq_notify",
	[185] = "mq_getsetattr",
	[186] = "msgget",
	[187] = "msgctl",
	[188] = "msgrcv",
	[189] = "msgsnd",
	[190] = "semget",
	[191] = "semctl",
	[192] = "semtimedop",
	[193] = "semop",
	[194] = "shmget",
	[195] = "shmctl",
	[196] = "shmat",
	[197] = "shmdt",
	[198] = "socket",
	[199] = "socketpair",
	[200] = "bind",
	[201] = "listen",
	[202] = "accept",
	[203] = "connect",
	[204] = "getsockname",
	[205] = "getpeername",
	[206] = "sendto",
	[207] = "recvfrom",
	[208] = "setsockopt",
	[209] = "getsockopt",
	[210] = "shutdown",
	[211] = "sendmsg",
	[212] = "recvmsg",
	[213] = "readahead",
	[214] = "brk",
	[215] = "munmap",
	[216] = "mremap",
	[217] = "add_key",
	[218] = "request_key",
	[219] = "keyctl",
	[220] = "clone",
	[221] = "execve",
	[222] = "mmap",
	[223] = "fadvise64",
	[224] = "swapon",
	[225] = "swapoff",
	[226] = "mprotect",
	[227] = "msync",
	[228] = "mlock",
	[229] = "munlock",
	[230] = "mlockall",
	[231] = "munlockall",
	[232] = "mincore",
	[233] = "madvise",
	[234] = "remap_file_pages",
	[235] = "mbind",
	[236] = "get_mempolicy",
	[237] = "set_mempolicy",
	[238] = "migrate_pages",
	[239] = "move_pages",
	[240] = "rt_tgsigqueueinfo",
	[241] = "perf_event_open",
	[242] = "accept4",
	[243] = "recvmmsg",
	[258] = "riscv_hwprobe",
	[259] = "riscv_flush_icache",
	[260] = "wait4",
	[261] = "prlimit64",
	[262] = "fanotify_init",
	[263] = "fanotify_mark",
	[264] = "name_to_handle_at",
	[265] = "open_by_handle_at",
	[266] = "clock_adjtime",
	[267] = "syncfs",
	[268] = "setns",
	[269] = "sendmmsg",
	[270] = "process_vm_readv",
	[271] = "process_vm_writev",
	[272] = "kcmp",
	[273] = "finit_module",
	[274] = "sched_setattr",
	[275] = "sched_getattr",
	[276] = "renameat2",
	[277] = "seccomp",
	[278] = "getrandom",
	[279] = "memfd_create",
	[280] = "bpf",
	[281] = "execveat",
	[282] = "userfaultfd",
	[283] = "membarrier",
	[284] = "mlock2",
	[285] = "copy_file_range",
	[286] = "preadv2",
	[287] = "pwritev2",
	[288] = "pkey_mprotect",
	[289] = "pkey_alloc",
	[290] = "pkey_free",
	[291] = "statx",
	[292] = "io_pgetevents",
	[293] = "rseq",
	[294] = "kexec_file_load",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[447] = "memfd_secret",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_RISCV[] = {
	202,	/* accept */
	242,	/* accept4 */
	89,	/* acct */
	217,	/* add_key */
	171,	/* adjtimex */
	200,	/* bind */
	280,	/* bpf */
	214,	/* brk */
	451,	/* cachestat */
	90,	/* capget */
	91,	/* capset */
	49,	/* chdir */
	51,	/* chroot */
	266,	/* clock_adjtime */
	114,	/* clock_getres */
	113,	/* clock_gettime */
	115,	/* clock_nanosleep */
	112,	/* clock_settime */
	220,	/* clone */
	435,	/* clone3 */
	57,	/* close */
	436,	/* close_range */
	203,	/* connect */
	285,	/* copy_file_range */
	106,	/* delete_module */
	23,	/* dup */
	24,	/* dup3 */
	20,	/* epoll_create1 */
	21,	/* epoll_ctl */
	22,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	19,	/* eventfd2 */
	221,	/* execve */
	281,	/* execveat */
	93,	/* exit */
	94,	/* exit_group */
	48,	/* faccessat */
	439,	/* faccessat2 */
	223,	/* fadvise64 */
	47,	/* fallocate */
	262,	/* fanotify_init */
	263,	/* fanotify_mark */
	50,	/* fchdir */
	52,	/* fchmod */
	53,	/* fchmodat */
	452,	/* fchmodat2 */
	55,	/* fchown */
	54,	/* fchownat */
	25,	/* fcntl */
	83,	/* fdatasync */
	10,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	273,	/* finit_module */
	13,	/* flistxattr */
	32,	/* flock */
	16,	/* fremovexattr */
	431,	/* fsconfig */
	7,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	80,	/* fstat */
	44,	/* fstatfs */
	82,	/* fsync */
	46,	/* ftruncate */
	98,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	236,	/* get_mempolicy */
	100,	/* get_robust_list */
	168,	/* getcpu */
	17,	/* getcwd */
	61,	/* getdents64 */
	177,	/* getegid */
	175,	/* geteuid */
	176,	/* getgid */
	158,	/* getgroups */
	102,	/* getitimer */
	205,	/* getpeername */
	155,	/* getpgid */
	172,	/* getpid */
	173,	/* getppid */
	141,	/* getpriority */
	278,	/* getrandom */
	150,	/* getresgid */
	148,	/* getresuid */
	163,	/* getrlimit */
	165,	/* getrusage */
	156,	/* getsid */
	204,	/* getsockname */
	209,	/* getsockopt */
	178,	/* gettid */
	169,	/* gettimeofday */
	174,	/* getuid */
	8,	/* getxattr */
	464,	/* getxattrat */
	105,	/* init_module */
	27,	/* inotify_add_watch */
	26,	/* inotify_init1 */
	28,	/* inotify_rm_watch */
	3,	/* io_cancel */
	1,	/* io_destroy */
	4,	/* io_getevents */
	292,	/* io_pgetevents */
	0,	/* io_setup */
	2,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	29,	/* ioctl */
	31,	/* ioprio_get */
	30,	/* ioprio_set */
	272,	/* kcmp */
	294,	/* kexec_file_load */
	104,	/* kexec_load */
	219,	/* keyctl */
	129,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	9,	/* lgetxattr */
	37,	/* linkat */
	201,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	11,	/* listxattr */
	465,	/* listxattrat */
	12,	/* llistxattr */
	18,	/* lookup_dcookie */
	15,	/* lremovexattr */
	62,	/* lseek */
	6,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	233,	/* madvise */
	453,	/* map_shadow_stack */
	235,	/* mbind */
	283,	/* membarrier */
	279,	/* memfd_create */
	447,	/* memfd_secret */
	238,	/* migrate_pages */
	232,	/* mincore */
	34,	/* mkdirat */
	33,	/* mknodat */
	228,	/* mlock */
	284,	/* mlock2 */
	230,	/* mlockall */
	222,	/* mmap */
	40,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	239,	/* move_pages */
	226,	/* mprotect */
	185,	/* mq_getsetattr */
	184,	/* mq_notify */
	180,	/* mq_open */
	183,	/* mq_timedreceive */
	182,	/* mq_timedsend */
	181,	/* mq_unlink */
	216,	/* mremap */
	462,	/* mseal */
	187,	/* msgctl */
	186,	/* msgget */
	188,	/* msgrcv */
	189,	/* msgsnd */
	227,	/* msync */
	229,	/* munlock */
	231,	/* munlockall */
	215,	/* munmap */
	264,	/* name_to_handle_at */
	101,	/* nanosleep */
	79,	/* newfstatat */
	42,	/* nfsservctl */
	265,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	56,	/* openat */
	437,	/* openat2 */
	241,	/* perf_event_open */
	92,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	59,	/* pipe2 */
	41,	/* pivot_root */
	289,	/* pkey_alloc */
	290,	/* pkey_free */
	288,	/* pkey_mprotect */
	73,	/* ppoll */
	167,	/* prctl */
	67,	/* pread64 */
	69,	/* preadv */
	286,	/* preadv2 */
	261,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	270,	/* process_vm_readv */
	271,	/* process_vm_writev */
	72,	/* pselect6 */
	117,	/* ptrace */
	68,	/* pwrite64 */
	70,	/* pwritev */
	287,	/* pwritev2 */
	60,	/* quotactl */
	443,	/* quotactl_fd */
	63,	/* read */
	213,	/* readahead */
	78,	/* readlinkat */
	65,	/* readv */
	142,	/* reboot */
	207,	/* recvfrom */
	243,	/* recvmmsg */
	212,	/* recvmsg */
	234,	/* remap_file_pages */
	14,	/* removexattr */
	466,	/* removexattrat */
	276,	/* renameat2 */
	218,	/* request_key */
	128,	/* restart_syscall */
	259,	/* riscv_flush_icache */
	258,	/* riscv_hwprobe */
	293,	/* rseq */
	471,	/* rseq_slice_yield */
	134,	/* rt_sigaction */
	136,	/* rt_sigpending */
	135,	/* rt_sigprocmask */
	138,	/* rt_sigqueueinfo */
	139,	/* rt_sigreturn */
	133,	/* rt_sigsuspend */
	137,	/* rt_sigtimedwait */
	240,	/* rt_tgsigqueueinfo */
	125,	/* sched_get_priority_max */
	126,	/* sched_get_priority_min */
	123,	/* sched_getaffinity */
	275,	/* sched_getattr */
	121,	/* sched_getparam */
	120,	/* sched_getscheduler */
	127,	/* sched_rr_get_interval */
	122,	/* sched_setaffinity */
	274,	/* sched_setattr */
	118,	/* sched_setparam */
	119,	/* sched_setscheduler */
	124,	/* sched_yield */
	277,	/* seccomp */
	191,	/* semctl */
	190,	/* semget */
	193,	/* semop */
	192,	/* semtimedop */
	71,	/* sendfile */
	269,	/* sendmmsg */
	211,	/* sendmsg */
	206,	/* sendto */
	237,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	99,	/* set_robust_list */
	96,	/* set_tid_address */
	162,	/* setdomainname */
	152,	/* setfsgid */
	151,	/* setfsuid */
	144,	/* setgid */
	159,	/* setgroups */
	161,	/* sethostname */
	103,	/* setitimer */
	268,	/* setns */
	154,	/* setpgid */
	140,	/* setpriority */
	143,	/* setregid */
	149,	/* setresgid */
	147,	/* setresuid */
	145,	/* setreuid */
	164,	/* setrlimit */
	157,	/* setsid */
	208,	/* setsockopt */
	170,	/* settimeofday */
	146,	/* setuid */
	5,	/* setxattr */
	463,	/* setxattrat */
	196,	/* shmat */
	195,	/* shmctl */
	197,	/* shmdt */
	194,	/* shmget */
	210,	/* shutdown */
	132,	/* sigaltstack */
	74,	/* signalfd4 */
	198,	/* socket */
	199,	/* socketpair */
	76,	/* splice */
	43,	/* statfs */
	457,	/* statmount */
	291,	/* statx */
	225,	/* swapoff */
	224,	/* swapon */
	36,	/* symlinkat */
	81,	/* sync */
	84,	/* sync_file_range */
	267,	/* syncfs */
	179,	/* sysinfo */
	116,	/* syslog */
	77,	/* tee */
	131,	/* tgkill */
	107,	/* timer_create */
	111,	/* timer_delete */
	109,	/* timer_getoverrun */
	108,	/* timer_gettime */
	110,	/* timer_settime */
	85,	/* timerfd_create */
	87,	/* timerfd_gettime */
	86,	/* timerfd_settime */
	153,	/* times */
	130,	/* tkill */
	45,	/* truncate */
	166,	/* umask */
	39,	/* umount2 */
	160,	/* uname */
	35,	/* unlinkat */
	97,	/* unshare */
	282,	/* userfaultfd */
	88,	/* utimensat */
	58,	/* vhangup */
	75,	/* vmsplice */
	260,	/* wait4 */
	95,	/* waitid */
	64,	/* write */
	66,	/* writev */
};
#endif //__BITS_PER_LONG != 64
#endif // defined(ALL_SYSCALLTBL) || defined(__riscv)
#if defined(ALL_SYSCALLTBL) || defined(__s390x__)
static const char *const syscall_num_to_name_EM_S390[] = {
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "restart_syscall",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execve",
	[12] = "chdir",
	[14] = "mknod",
	[15] = "chmod",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "mount",
	[22] = "umount",
	[26] = "ptrace",
	[27] = "alarm",
	[29] = "pause",
	[30] = "utime",
	[33] = "access",
	[34] = "nice",
	[36] = "sync",
	[37] = "kill",
	[38] = "rename",
	[39] = "mkdir",
	[40] = "rmdir",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[45] = "brk",
	[48] = "signal",
	[51] = "acct",
	[52] = "umount2",
	[54] = "ioctl",
	[55] = "fcntl",
	[57] = "setpgid",
	[60] = "umask",
	[61] = "chroot",
	[62] = "ustat",
	[63] = "dup2",
	[64] = "getppid",
	[65] = "getpgrp",
	[66] = "setsid",
	[67] = "sigaction",
	[72] = "sigsuspend",
	[73] = "sigpending",
	[74] = "sethostname",
	[75] = "setrlimit",
	[77] = "getrusage",
	[78] = "gettimeofday",
	[79] = "settimeofday",
	[83] = "symlink",
	[85] = "readlink",
	[86] = "uselib",
	[87] = "swapon",
	[88] = "reboot",
	[89] = "readdir",
	[90] = "mmap",
	[91] = "munmap",
	[92] = "truncate",
	[93] = "ftruncate",
	[94] = "fchmod",
	[96] = "getpriority",
	[97] = "setpriority",
	[99] = "statfs",
	[100] = "fstatfs",
	[102] = "socketcall",
	[103] = "syslog",
	[104] = "setitimer",
	[105] = "getitimer",
	[106] = "stat",
	[107] = "lstat",
	[108] = "fstat",
	[110] = "lookup_dcookie",
	[111] = "vhangup",
	[112] = "idle",
	[114] = "wait4",
	[115] = "swapoff",
	[116] = "sysinfo",
	[117] = "ipc",
	[118] = "fsync",
	[119] = "sigreturn",
	[120] = "clone",
	[121] = "setdomainname",
	[122] = "uname",
	[124] = "adjtimex",
	[125] = "mprotect",
	[126] = "sigprocmask",
	[127] = "create_module",
	[128] = "init_module",
	[129] = "delete_module",
	[130] = "get_kernel_syms",
	[131] = "quotactl",
	[132] = "getpgid",
	[133] = "fchdir",
	[134] = "bdflush",
	[135] = "sysfs",
	[136] = "personality",
	[137] = "afs_syscall",
	[141] = "getdents",
	[142] = "select",
	[143] = "flock",
	[144] = "msync",
	[145] = "readv",
	[146] = "writev",
	[147] = "getsid",
	[148] = "fdatasync",
	[149] = "_sysctl",
	[150] = "mlock",
	[151] = "munlock",
	[152] = "mlockall",
	[153] = "munlockall",
	[154] = "sched_setparam",
	[155] = "sched_getparam",
	[156] = "sched_setscheduler",
	[157] = "sched_getscheduler",
	[158] = "sched_yield",
	[159] = "sched_get_priority_max",
	[160] = "sched_get_priority_min",
	[161] = "sched_rr_get_interval",
	[162] = "nanosleep",
	[163] = "mremap",
	[167] = "query_module",
	[168] = "poll",
	[169] = "nfsservctl",
	[172] = "prctl",
	[173] = "rt_sigreturn",
	[174] = "rt_sigaction",
	[175] = "rt_sigprocmask",
	[176] = "rt_sigpending",
	[177] = "rt_sigtimedwait",
	[178] = "rt_sigqueueinfo",
	[179] = "rt_sigsuspend",
	[180] = "pread64",
	[181] = "pwrite64",
	[183] = "getcwd",
	[184] = "capget",
	[185] = "capset",
	[186] = "sigaltstack",
	[187] = "sendfile",
	[188] = "getpmsg",
	[189] = "putpmsg",
	[190] = "vfork",
	[191] = "getrlimit",
	[198] = "lchown",
	[199] = "getuid",
	[200] = "getgid",
	[201] = "geteuid",
	[202] = "getegid",
	[203] = "setreuid",
	[204] = "setregid",
	[205] = "getgroups",
	[206] = "setgroups",
	[207] = "fchown",
	[208] = "setresuid",
	[209] = "getresuid",
	[210] = "setresgid",
	[211] = "getresgid",
	[212] = "chown",
	[213] = "setuid",
	[214] = "setgid",
	[215] = "setfsuid",
	[216] = "setfsgid",
	[217] = "pivot_root",
	[218] = "mincore",
	[219] = "madvise",
	[220] = "getdents64",
	[222] = "readahead",
	[224] = "setxattr",
	[225] = "lsetxattr",
	[226] = "fsetxattr",
	[227] = "getxattr",
	[228] = "lgetxattr",
	[229] = "fgetxattr",
	[230] = "listxattr",
	[231] = "llistxattr",
	[232] = "flistxattr",
	[233] = "removexattr",
	[234] = "lremovexattr",
	[235] = "fremovexattr",
	[236] = "gettid",
	[237] = "tkill",
	[238] = "futex",
	[239] = "sched_setaffinity",
	[240] = "sched_getaffinity",
	[241] = "tgkill",
	[243] = "io_setup",
	[244] = "io_destroy",
	[245] = "io_getevents",
	[246] = "io_submit",
	[247] = "io_cancel",
	[248] = "exit_group",
	[249] = "epoll_create",
	[250] = "epoll_ctl",
	[251] = "epoll_wait",
	[252] = "set_tid_address",
	[253] = "fadvise64",
	[254] = "timer_create",
	[255] = "timer_settime",
	[256] = "timer_gettime",
	[257] = "timer_getoverrun",
	[258] = "timer_delete",
	[259] = "clock_settime",
	[260] = "clock_gettime",
	[261] = "clock_getres",
	[262] = "clock_nanosleep",
	[265] = "statfs64",
	[266] = "fstatfs64",
	[267] = "remap_file_pages",
	[268] = "mbind",
	[269] = "get_mempolicy",
	[270] = "set_mempolicy",
	[271] = "mq_open",
	[272] = "mq_unlink",
	[273] = "mq_timedsend",
	[274] = "mq_timedreceive",
	[275] = "mq_notify",
	[276] = "mq_getsetattr",
	[277] = "kexec_load",
	[278] = "add_key",
	[279] = "request_key",
	[280] = "keyctl",
	[281] = "waitid",
	[282] = "ioprio_set",
	[283] = "ioprio_get",
	[284] = "inotify_init",
	[285] = "inotify_add_watch",
	[286] = "inotify_rm_watch",
	[287] = "migrate_pages",
	[288] = "openat",
	[289] = "mkdirat",
	[290] = "mknodat",
	[291] = "fchownat",
	[292] = "futimesat",
	[293] = "newfstatat",
	[294] = "unlinkat",
	[295] = "renameat",
	[296] = "linkat",
	[297] = "symlinkat",
	[298] = "readlinkat",
	[299] = "fchmodat",
	[300] = "faccessat",
	[301] = "pselect6",
	[302] = "ppoll",
	[303] = "unshare",
	[304] = "set_robust_list",
	[305] = "get_robust_list",
	[306] = "splice",
	[307] = "sync_file_range",
	[308] = "tee",
	[309] = "vmsplice",
	[310] = "move_pages",
	[311] = "getcpu",
	[312] = "epoll_pwait",
	[313] = "utimes",
	[314] = "fallocate",
	[315] = "utimensat",
	[316] = "signalfd",
	[317] = "timerfd",
	[318] = "eventfd",
	[319] = "timerfd_create",
	[320] = "timerfd_settime",
	[321] = "timerfd_gettime",
	[322] = "signalfd4",
	[323] = "eventfd2",
	[324] = "inotify_init1",
	[325] = "pipe2",
	[326] = "dup3",
	[327] = "epoll_create1",
	[328] = "preadv",
	[329] = "pwritev",
	[330] = "rt_tgsigqueueinfo",
	[331] = "perf_event_open",
	[332] = "fanotify_init",
	[333] = "fanotify_mark",
	[334] = "prlimit64",
	[335] = "name_to_handle_at",
	[336] = "open_by_handle_at",
	[337] = "clock_adjtime",
	[338] = "syncfs",
	[339] = "setns",
	[340] = "process_vm_readv",
	[341] = "process_vm_writev",
	[342] = "s390_runtime_instr",
	[343] = "kcmp",
	[344] = "finit_module",
	[345] = "sched_setattr",
	[346] = "sched_getattr",
	[347] = "renameat2",
	[348] = "seccomp",
	[349] = "getrandom",
	[350] = "memfd_create",
	[351] = "bpf",
	[352] = "s390_pci_mmio_write",
	[353] = "s390_pci_mmio_read",
	[354] = "execveat",
	[355] = "userfaultfd",
	[356] = "membarrier",
	[357] = "recvmmsg",
	[358] = "sendmmsg",
	[359] = "socket",
	[360] = "socketpair",
	[361] = "bind",
	[362] = "connect",
	[363] = "listen",
	[364] = "accept4",
	[365] = "getsockopt",
	[366] = "setsockopt",
	[367] = "getsockname",
	[368] = "getpeername",
	[369] = "sendto",
	[370] = "sendmsg",
	[371] = "recvfrom",
	[372] = "recvmsg",
	[373] = "shutdown",
	[374] = "mlock2",
	[375] = "copy_file_range",
	[376] = "preadv2",
	[377] = "pwritev2",
	[378] = "s390_guarded_storage",
	[379] = "statx",
	[380] = "s390_sthyi",
	[381] = "kexec_file_load",
	[382] = "io_pgetevents",
	[383] = "rseq",
	[384] = "pkey_mprotect",
	[385] = "pkey_alloc",
	[386] = "pkey_free",
	[392] = "semtimedop",
	[393] = "semget",
	[394] = "semctl",
	[395] = "shmget",
	[396] = "shmctl",
	[397] = "shmat",
	[398] = "shmdt",
	[399] = "msgget",
	[400] = "msgsnd",
	[401] = "msgrcv",
	[402] = "msgctl",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[447] = "memfd_secret",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_S390[] = {
	149,	/* _sysctl */
	364,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	278,	/* add_key */
	124,	/* adjtimex */
	137,	/* afs_syscall */
	27,	/* alarm */
	134,	/* bdflush */
	361,	/* bind */
	351,	/* bpf */
	45,	/* brk */
	451,	/* cachestat */
	184,	/* capget */
	185,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	212,	/* chown */
	61,	/* chroot */
	337,	/* clock_adjtime */
	261,	/* clock_getres */
	260,	/* clock_gettime */
	262,	/* clock_nanosleep */
	259,	/* clock_settime */
	120,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	362,	/* connect */
	375,	/* copy_file_range */
	8,	/* creat */
	127,	/* create_module */
	129,	/* delete_module */
	41,	/* dup */
	63,	/* dup2 */
	326,	/* dup3 */
	249,	/* epoll_create */
	327,	/* epoll_create1 */
	250,	/* epoll_ctl */
	312,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	251,	/* epoll_wait */
	318,	/* eventfd */
	323,	/* eventfd2 */
	11,	/* execve */
	354,	/* execveat */
	1,	/* exit */
	248,	/* exit_group */
	300,	/* faccessat */
	439,	/* faccessat2 */
	253,	/* fadvise64 */
	314,	/* fallocate */
	332,	/* fanotify_init */
	333,	/* fanotify_mark */
	133,	/* fchdir */
	94,	/* fchmod */
	299,	/* fchmodat */
	452,	/* fchmodat2 */
	207,	/* fchown */
	291,	/* fchownat */
	55,	/* fcntl */
	148,	/* fdatasync */
	229,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	344,	/* finit_module */
	232,	/* flistxattr */
	143,	/* flock */
	2,	/* fork */
	235,	/* fremovexattr */
	431,	/* fsconfig */
	226,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	108,	/* fstat */
	100,	/* fstatfs */
	266,	/* fstatfs64 */
	118,	/* fsync */
	93,	/* ftruncate */
	238,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	292,	/* futimesat */
	130,	/* get_kernel_syms */
	269,	/* get_mempolicy */
	305,	/* get_robust_list */
	311,	/* getcpu */
	183,	/* getcwd */
	141,	/* getdents */
	220,	/* getdents64 */
	202,	/* getegid */
	201,	/* geteuid */
	200,	/* getgid */
	205,	/* getgroups */
	105,	/* getitimer */
	368,	/* getpeername */
	132,	/* getpgid */
	65,	/* getpgrp */
	20,	/* getpid */
	188,	/* getpmsg */
	64,	/* getppid */
	96,	/* getpriority */
	349,	/* getrandom */
	211,	/* getresgid */
	209,	/* getresuid */
	191,	/* getrlimit */
	77,	/* getrusage */
	147,	/* getsid */
	367,	/* getsockname */
	365,	/* getsockopt */
	236,	/* gettid */
	78,	/* gettimeofday */
	199,	/* getuid */
	227,	/* getxattr */
	464,	/* getxattrat */
	112,	/* idle */
	128,	/* init_module */
	285,	/* inotify_add_watch */
	284,	/* inotify_init */
	324,	/* inotify_init1 */
	286,	/* inotify_rm_watch */
	247,	/* io_cancel */
	244,	/* io_destroy */
	245,	/* io_getevents */
	382,	/* io_pgetevents */
	243,	/* io_setup */
	246,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	283,	/* ioprio_get */
	282,	/* ioprio_set */
	117,	/* ipc */
	343,	/* kcmp */
	381,	/* kexec_file_load */
	277,	/* kexec_load */
	280,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	198,	/* lchown */
	228,	/* lgetxattr */
	9,	/* link */
	296,	/* linkat */
	363,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	230,	/* listxattr */
	465,	/* listxattrat */
	231,	/* llistxattr */
	110,	/* lookup_dcookie */
	234,	/* lremovexattr */
	19,	/* lseek */
	225,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	107,	/* lstat */
	219,	/* madvise */
	453,	/* map_shadow_stack */
	268,	/* mbind */
	356,	/* membarrier */
	350,	/* memfd_create */
	447,	/* memfd_secret */
	287,	/* migrate_pages */
	218,	/* mincore */
	39,	/* mkdir */
	289,	/* mkdirat */
	14,	/* mknod */
	290,	/* mknodat */
	150,	/* mlock */
	374,	/* mlock2 */
	152,	/* mlockall */
	90,	/* mmap */
	21,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	310,	/* move_pages */
	125,	/* mprotect */
	276,	/* mq_getsetattr */
	275,	/* mq_notify */
	271,	/* mq_open */
	274,	/* mq_timedreceive */
	273,	/* mq_timedsend */
	272,	/* mq_unlink */
	163,	/* mremap */
	462,	/* mseal */
	402,	/* msgctl */
	399,	/* msgget */
	401,	/* msgrcv */
	400,	/* msgsnd */
	144,	/* msync */
	151,	/* munlock */
	153,	/* munlockall */
	91,	/* munmap */
	335,	/* name_to_handle_at */
	162,	/* nanosleep */
	293,	/* newfstatat */
	169,	/* nfsservctl */
	34,	/* nice */
	5,	/* open */
	336,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	288,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	331,	/* perf_event_open */
	136,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	325,	/* pipe2 */
	217,	/* pivot_root */
	385,	/* pkey_alloc */
	386,	/* pkey_free */
	384,	/* pkey_mprotect */
	168,	/* poll */
	302,	/* ppoll */
	172,	/* prctl */
	180,	/* pread64 */
	328,	/* preadv */
	376,	/* preadv2 */
	334,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	340,	/* process_vm_readv */
	341,	/* process_vm_writev */
	301,	/* pselect6 */
	26,	/* ptrace */
	189,	/* putpmsg */
	181,	/* pwrite64 */
	329,	/* pwritev */
	377,	/* pwritev2 */
	167,	/* query_module */
	131,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	222,	/* readahead */
	89,	/* readdir */
	85,	/* readlink */
	298,	/* readlinkat */
	145,	/* readv */
	88,	/* reboot */
	371,	/* recvfrom */
	357,	/* recvmmsg */
	372,	/* recvmsg */
	267,	/* remap_file_pages */
	233,	/* removexattr */
	466,	/* removexattrat */
	38,	/* rename */
	295,	/* renameat */
	347,	/* renameat2 */
	279,	/* request_key */
	7,	/* restart_syscall */
	40,	/* rmdir */
	383,	/* rseq */
	471,	/* rseq_slice_yield */
	174,	/* rt_sigaction */
	176,	/* rt_sigpending */
	175,	/* rt_sigprocmask */
	178,	/* rt_sigqueueinfo */
	173,	/* rt_sigreturn */
	179,	/* rt_sigsuspend */
	177,	/* rt_sigtimedwait */
	330,	/* rt_tgsigqueueinfo */
	378,	/* s390_guarded_storage */
	353,	/* s390_pci_mmio_read */
	352,	/* s390_pci_mmio_write */
	342,	/* s390_runtime_instr */
	380,	/* s390_sthyi */
	159,	/* sched_get_priority_max */
	160,	/* sched_get_priority_min */
	240,	/* sched_getaffinity */
	346,	/* sched_getattr */
	155,	/* sched_getparam */
	157,	/* sched_getscheduler */
	161,	/* sched_rr_get_interval */
	239,	/* sched_setaffinity */
	345,	/* sched_setattr */
	154,	/* sched_setparam */
	156,	/* sched_setscheduler */
	158,	/* sched_yield */
	348,	/* seccomp */
	142,	/* select */
	394,	/* semctl */
	393,	/* semget */
	392,	/* semtimedop */
	187,	/* sendfile */
	358,	/* sendmmsg */
	370,	/* sendmsg */
	369,	/* sendto */
	270,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	304,	/* set_robust_list */
	252,	/* set_tid_address */
	121,	/* setdomainname */
	216,	/* setfsgid */
	215,	/* setfsuid */
	214,	/* setgid */
	206,	/* setgroups */
	74,	/* sethostname */
	104,	/* setitimer */
	339,	/* setns */
	57,	/* setpgid */
	97,	/* setpriority */
	204,	/* setregid */
	210,	/* setresgid */
	208,	/* setresuid */
	203,	/* setreuid */
	75,	/* setrlimit */
	66,	/* setsid */
	366,	/* setsockopt */
	79,	/* settimeofday */
	213,	/* setuid */
	224,	/* setxattr */
	463,	/* setxattrat */
	397,	/* shmat */
	396,	/* shmctl */
	398,	/* shmdt */
	395,	/* shmget */
	373,	/* shutdown */
	67,	/* sigaction */
	186,	/* sigaltstack */
	48,	/* signal */
	316,	/* signalfd */
	322,	/* signalfd4 */
	73,	/* sigpending */
	126,	/* sigprocmask */
	119,	/* sigreturn */
	72,	/* sigsuspend */
	359,	/* socket */
	102,	/* socketcall */
	360,	/* socketpair */
	306,	/* splice */
	106,	/* stat */
	99,	/* statfs */
	265,	/* statfs64 */
	457,	/* statmount */
	379,	/* statx */
	115,	/* swapoff */
	87,	/* swapon */
	83,	/* symlink */
	297,	/* symlinkat */
	36,	/* sync */
	307,	/* sync_file_range */
	338,	/* syncfs */
	135,	/* sysfs */
	116,	/* sysinfo */
	103,	/* syslog */
	308,	/* tee */
	241,	/* tgkill */
	254,	/* timer_create */
	258,	/* timer_delete */
	257,	/* timer_getoverrun */
	256,	/* timer_gettime */
	255,	/* timer_settime */
	317,	/* timerfd */
	319,	/* timerfd_create */
	321,	/* timerfd_gettime */
	320,	/* timerfd_settime */
	43,	/* times */
	237,	/* tkill */
	92,	/* truncate */
	60,	/* umask */
	22,	/* umount */
	52,	/* umount2 */
	122,	/* uname */
	10,	/* unlink */
	294,	/* unlinkat */
	303,	/* unshare */
	86,	/* uselib */
	355,	/* userfaultfd */
	62,	/* ustat */
	30,	/* utime */
	315,	/* utimensat */
	313,	/* utimes */
	190,	/* vfork */
	111,	/* vhangup */
	309,	/* vmsplice */
	114,	/* wait4 */
	281,	/* waitid */
	4,	/* write */
	146,	/* writev */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__s390x__)

#if defined(ALL_SYSCALLTBL) || defined(__sh__)
static const char *const syscall_num_to_name_EM_SH[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "waitpid",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execve",
	[12] = "chdir",
	[13] = "time",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[18] = "oldstat",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "mount",
	[22] = "umount",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "stime",
	[26] = "ptrace",
	[27] = "alarm",
	[28] = "oldfstat",
	[29] = "pause",
	[30] = "utime",
	[33] = "access",
	[34] = "nice",
	[36] = "sync",
	[37] = "kill",
	[38] = "rename",
	[39] = "mkdir",
	[40] = "rmdir",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[45] = "brk",
	[46] = "setgid",
	[47] = "getgid",
	[48] = "signal",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[52] = "umount2",
	[54] = "ioctl",
	[55] = "fcntl",
	[57] = "setpgid",
	[60] = "umask",
	[61] = "chroot",
	[62] = "ustat",
	[63] = "dup2",
	[64] = "getppid",
	[65] = "getpgrp",
	[66] = "setsid",
	[67] = "sigaction",
	[68] = "sgetmask",
	[69] = "ssetmask",
	[70] = "setreuid",
	[71] = "setregid",
	[72] = "sigsuspend",
	[73] = "sigpending",
	[74] = "sethostname",
	[75] = "setrlimit",
	[76] = "getrlimit",
	[77] = "getrusage",
	[78] = "gettimeofday",
	[79] = "settimeofday",
	[80] = "getgroups",
	[81] = "setgroups",
	[83] = "symlink",
	[84] = "oldlstat",
	[85] = "readlink",
	[86] = "uselib",
	[87] = "swapon",
	[88] = "reboot",
	[89] = "readdir",
	[90] = "mmap",
	[91] = "munmap",
	[92] = "truncate",
	[93] = "ftruncate",
	[94] = "fchmod",
	[95] = "fchown",
	[96] = "getpriority",
	[97] = "setpriority",
	[99] = "statfs",
	[100] = "fstatfs",
	[102] = "socketcall",
	[103] = "syslog",
	[104] = "setitimer",
	[105] = "getitimer",
	[106] = "stat",
	[107] = "lstat",
	[108] = "fstat",
	[109] = "olduname",
	[111] = "vhangup",
	[114] = "wait4",
	[115] = "swapoff",
	[116] = "sysinfo",
	[117] = "ipc",
	[118] = "fsync",
	[119] = "sigreturn",
	[120] = "clone",
	[121] = "setdomainname",
	[122] = "uname",
	[123] = "cacheflush",
	[124] = "adjtimex",
	[125] = "mprotect",
	[126] = "sigprocmask",
	[128] = "init_module",
	[129] = "delete_module",
	[131] = "quotactl",
	[132] = "getpgid",
	[133] = "fchdir",
	[134] = "bdflush",
	[135] = "sysfs",
	[136] = "personality",
	[138] = "setfsuid",
	[139] = "setfsgid",
	[140] = "_llseek",
	[141] = "getdents",
	[142] = "_newselect",
	[143] = "flock",
	[144] = "msync",
	[145] = "readv",
	[146] = "writev",
	[147] = "getsid",
	[148] = "fdatasync",
	[149] = "_sysctl",
	[150] = "mlock",
	[151] = "munlock",
	[152] = "mlockall",
	[153] = "munlockall",
	[154] = "sched_setparam",
	[155] = "sched_getparam",
	[156] = "sched_setscheduler",
	[157] = "sched_getscheduler",
	[158] = "sched_yield",
	[159] = "sched_get_priority_max",
	[160] = "sched_get_priority_min",
	[161] = "sched_rr_get_interval",
	[162] = "nanosleep",
	[163] = "mremap",
	[164] = "setresuid",
	[165] = "getresuid",
	[168] = "poll",
	[169] = "nfsservctl",
	[170] = "setresgid",
	[171] = "getresgid",
	[172] = "prctl",
	[173] = "rt_sigreturn",
	[174] = "rt_sigaction",
	[175] = "rt_sigprocmask",
	[176] = "rt_sigpending",
	[177] = "rt_sigtimedwait",
	[178] = "rt_sigqueueinfo",
	[179] = "rt_sigsuspend",
	[180] = "pread64",
	[181] = "pwrite64",
	[182] = "chown",
	[183] = "getcwd",
	[184] = "capget",
	[185] = "capset",
	[186] = "sigaltstack",
	[187] = "sendfile",
	[190] = "vfork",
	[191] = "ugetrlimit",
	[192] = "mmap2",
	[193] = "truncate64",
	[194] = "ftruncate64",
	[195] = "stat64",
	[196] = "lstat64",
	[197] = "fstat64",
	[198] = "lchown32",
	[199] = "getuid32",
	[200] = "getgid32",
	[201] = "geteuid32",
	[202] = "getegid32",
	[203] = "setreuid32",
	[204] = "setregid32",
	[205] = "getgroups32",
	[206] = "setgroups32",
	[207] = "fchown32",
	[208] = "setresuid32",
	[209] = "getresuid32",
	[210] = "setresgid32",
	[211] = "getresgid32",
	[212] = "chown32",
	[213] = "setuid32",
	[214] = "setgid32",
	[215] = "setfsuid32",
	[216] = "setfsgid32",
	[217] = "pivot_root",
	[218] = "mincore",
	[219] = "madvise",
	[220] = "getdents64",
	[221] = "fcntl64",
	[224] = "gettid",
	[225] = "readahead",
	[226] = "setxattr",
	[227] = "lsetxattr",
	[228] = "fsetxattr",
	[229] = "getxattr",
	[230] = "lgetxattr",
	[231] = "fgetxattr",
	[232] = "listxattr",
	[233] = "llistxattr",
	[234] = "flistxattr",
	[235] = "removexattr",
	[236] = "lremovexattr",
	[237] = "fremovexattr",
	[238] = "tkill",
	[239] = "sendfile64",
	[240] = "futex",
	[241] = "sched_setaffinity",
	[242] = "sched_getaffinity",
	[245] = "io_setup",
	[246] = "io_destroy",
	[247] = "io_getevents",
	[248] = "io_submit",
	[249] = "io_cancel",
	[250] = "fadvise64",
	[252] = "exit_group",
	[253] = "lookup_dcookie",
	[254] = "epoll_create",
	[255] = "epoll_ctl",
	[256] = "epoll_wait",
	[257] = "remap_file_pages",
	[258] = "set_tid_address",
	[259] = "timer_create",
	[260] = "timer_settime",
	[261] = "timer_gettime",
	[262] = "timer_getoverrun",
	[263] = "timer_delete",
	[264] = "clock_settime",
	[265] = "clock_gettime",
	[266] = "clock_getres",
	[267] = "clock_nanosleep",
	[268] = "statfs64",
	[269] = "fstatfs64",
	[270] = "tgkill",
	[271] = "utimes",
	[272] = "fadvise64_64",
	[274] = "mbind",
	[275] = "get_mempolicy",
	[276] = "set_mempolicy",
	[277] = "mq_open",
	[278] = "mq_unlink",
	[279] = "mq_timedsend",
	[280] = "mq_timedreceive",
	[281] = "mq_notify",
	[282] = "mq_getsetattr",
	[283] = "kexec_load",
	[284] = "waitid",
	[285] = "add_key",
	[286] = "request_key",
	[287] = "keyctl",
	[288] = "ioprio_set",
	[289] = "ioprio_get",
	[290] = "inotify_init",
	[291] = "inotify_add_watch",
	[292] = "inotify_rm_watch",
	[294] = "migrate_pages",
	[295] = "openat",
	[296] = "mkdirat",
	[297] = "mknodat",
	[298] = "fchownat",
	[299] = "futimesat",
	[300] = "fstatat64",
	[301] = "unlinkat",
	[302] = "renameat",
	[303] = "linkat",
	[304] = "symlinkat",
	[305] = "readlinkat",
	[306] = "fchmodat",
	[307] = "faccessat",
	[308] = "pselect6",
	[309] = "ppoll",
	[310] = "unshare",
	[311] = "set_robust_list",
	[312] = "get_robust_list",
	[313] = "splice",
	[314] = "sync_file_range",
	[315] = "tee",
	[316] = "vmsplice",
	[317] = "move_pages",
	[318] = "getcpu",
	[319] = "epoll_pwait",
	[320] = "utimensat",
	[321] = "signalfd",
	[322] = "timerfd_create",
	[323] = "eventfd",
	[324] = "fallocate",
	[325] = "timerfd_settime",
	[326] = "timerfd_gettime",
	[327] = "signalfd4",
	[328] = "eventfd2",
	[329] = "epoll_create1",
	[330] = "dup3",
	[331] = "pipe2",
	[332] = "inotify_init1",
	[333] = "preadv",
	[334] = "pwritev",
	[335] = "rt_tgsigqueueinfo",
	[336] = "perf_event_open",
	[337] = "fanotify_init",
	[338] = "fanotify_mark",
	[339] = "prlimit64",
	[340] = "socket",
	[341] = "bind",
	[342] = "connect",
	[343] = "listen",
	[344] = "accept",
	[345] = "getsockname",
	[346] = "getpeername",
	[347] = "socketpair",
	[348] = "send",
	[349] = "sendto",
	[350] = "recv",
	[351] = "recvfrom",
	[352] = "shutdown",
	[353] = "setsockopt",
	[354] = "getsockopt",
	[355] = "sendmsg",
	[356] = "recvmsg",
	[357] = "recvmmsg",
	[358] = "accept4",
	[359] = "name_to_handle_at",
	[360] = "open_by_handle_at",
	[361] = "clock_adjtime",
	[362] = "syncfs",
	[363] = "sendmmsg",
	[364] = "setns",
	[365] = "process_vm_readv",
	[366] = "process_vm_writev",
	[367] = "kcmp",
	[368] = "finit_module",
	[369] = "sched_getattr",
	[370] = "sched_setattr",
	[371] = "renameat2",
	[372] = "seccomp",
	[373] = "getrandom",
	[374] = "memfd_create",
	[375] = "bpf",
	[376] = "execveat",
	[377] = "userfaultfd",
	[378] = "membarrier",
	[379] = "mlock2",
	[380] = "copy_file_range",
	[381] = "preadv2",
	[382] = "pwritev2",
	[383] = "statx",
	[384] = "pkey_mprotect",
	[385] = "pkey_alloc",
	[386] = "pkey_free",
	[387] = "rseq",
	[388] = "sync_file_range2",
	[393] = "semget",
	[394] = "semctl",
	[395] = "shmget",
	[396] = "shmctl",
	[397] = "shmat",
	[398] = "shmdt",
	[399] = "msgget",
	[400] = "msgsnd",
	[401] = "msgrcv",
	[402] = "msgctl",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_SH[] = {
	140,	/* _llseek */
	142,	/* _newselect */
	149,	/* _sysctl */
	344,	/* accept */
	358,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	285,	/* add_key */
	124,	/* adjtimex */
	27,	/* alarm */
	134,	/* bdflush */
	341,	/* bind */
	375,	/* bpf */
	45,	/* brk */
	123,	/* cacheflush */
	451,	/* cachestat */
	184,	/* capget */
	185,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	182,	/* chown */
	212,	/* chown32 */
	61,	/* chroot */
	361,	/* clock_adjtime */
	405,	/* clock_adjtime64 */
	266,	/* clock_getres */
	406,	/* clock_getres_time64 */
	265,	/* clock_gettime */
	403,	/* clock_gettime64 */
	267,	/* clock_nanosleep */
	407,	/* clock_nanosleep_time64 */
	264,	/* clock_settime */
	404,	/* clock_settime64 */
	120,	/* clone */
	6,	/* close */
	436,	/* close_range */
	342,	/* connect */
	380,	/* copy_file_range */
	8,	/* creat */
	129,	/* delete_module */
	41,	/* dup */
	63,	/* dup2 */
	330,	/* dup3 */
	254,	/* epoll_create */
	329,	/* epoll_create1 */
	255,	/* epoll_ctl */
	319,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	256,	/* epoll_wait */
	323,	/* eventfd */
	328,	/* eventfd2 */
	11,	/* execve */
	376,	/* execveat */
	1,	/* exit */
	252,	/* exit_group */
	307,	/* faccessat */
	439,	/* faccessat2 */
	250,	/* fadvise64 */
	272,	/* fadvise64_64 */
	324,	/* fallocate */
	337,	/* fanotify_init */
	338,	/* fanotify_mark */
	133,	/* fchdir */
	94,	/* fchmod */
	306,	/* fchmodat */
	452,	/* fchmodat2 */
	95,	/* fchown */
	207,	/* fchown32 */
	298,	/* fchownat */
	55,	/* fcntl */
	221,	/* fcntl64 */
	148,	/* fdatasync */
	231,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	368,	/* finit_module */
	234,	/* flistxattr */
	143,	/* flock */
	2,	/* fork */
	237,	/* fremovexattr */
	431,	/* fsconfig */
	228,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	108,	/* fstat */
	197,	/* fstat64 */
	300,	/* fstatat64 */
	100,	/* fstatfs */
	269,	/* fstatfs64 */
	118,	/* fsync */
	93,	/* ftruncate */
	194,	/* ftruncate64 */
	240,	/* futex */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	299,	/* futimesat */
	275,	/* get_mempolicy */
	312,	/* get_robust_list */
	318,	/* getcpu */
	183,	/* getcwd */
	141,	/* getdents */
	220,	/* getdents64 */
	50,	/* getegid */
	202,	/* getegid32 */
	49,	/* geteuid */
	201,	/* geteuid32 */
	47,	/* getgid */
	200,	/* getgid32 */
	80,	/* getgroups */
	205,	/* getgroups32 */
	105,	/* getitimer */
	346,	/* getpeername */
	132,	/* getpgid */
	65,	/* getpgrp */
	20,	/* getpid */
	64,	/* getppid */
	96,	/* getpriority */
	373,	/* getrandom */
	171,	/* getresgid */
	211,	/* getresgid32 */
	165,	/* getresuid */
	209,	/* getresuid32 */
	76,	/* getrlimit */
	77,	/* getrusage */
	147,	/* getsid */
	345,	/* getsockname */
	354,	/* getsockopt */
	224,	/* gettid */
	78,	/* gettimeofday */
	24,	/* getuid */
	199,	/* getuid32 */
	229,	/* getxattr */
	464,	/* getxattrat */
	128,	/* init_module */
	291,	/* inotify_add_watch */
	290,	/* inotify_init */
	332,	/* inotify_init1 */
	292,	/* inotify_rm_watch */
	249,	/* io_cancel */
	246,	/* io_destroy */
	247,	/* io_getevents */
	416,	/* io_pgetevents_time64 */
	245,	/* io_setup */
	248,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	289,	/* ioprio_get */
	288,	/* ioprio_set */
	117,	/* ipc */
	367,	/* kcmp */
	283,	/* kexec_load */
	287,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	198,	/* lchown32 */
	230,	/* lgetxattr */
	9,	/* link */
	303,	/* linkat */
	343,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	232,	/* listxattr */
	465,	/* listxattrat */
	233,	/* llistxattr */
	253,	/* lookup_dcookie */
	236,	/* lremovexattr */
	19,	/* lseek */
	227,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	107,	/* lstat */
	196,	/* lstat64 */
	219,	/* madvise */
	453,	/* map_shadow_stack */
	274,	/* mbind */
	378,	/* membarrier */
	374,	/* memfd_create */
	294,	/* migrate_pages */
	218,	/* mincore */
	39,	/* mkdir */
	296,	/* mkdirat */
	14,	/* mknod */
	297,	/* mknodat */
	150,	/* mlock */
	379,	/* mlock2 */
	152,	/* mlockall */
	90,	/* mmap */
	192,	/* mmap2 */
	21,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	317,	/* move_pages */
	125,	/* mprotect */
	282,	/* mq_getsetattr */
	281,	/* mq_notify */
	277,	/* mq_open */
	280,	/* mq_timedreceive */
	419,	/* mq_timedreceive_time64 */
	279,	/* mq_timedsend */
	418,	/* mq_timedsend_time64 */
	278,	/* mq_unlink */
	163,	/* mremap */
	462,	/* mseal */
	402,	/* msgctl */
	399,	/* msgget */
	401,	/* msgrcv */
	400,	/* msgsnd */
	144,	/* msync */
	151,	/* munlock */
	153,	/* munlockall */
	91,	/* munmap */
	359,	/* name_to_handle_at */
	162,	/* nanosleep */
	169,	/* nfsservctl */
	34,	/* nice */
	28,	/* oldfstat */
	84,	/* oldlstat */
	18,	/* oldstat */
	109,	/* olduname */
	5,	/* open */
	360,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	295,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	336,	/* perf_event_open */
	136,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	331,	/* pipe2 */
	217,	/* pivot_root */
	385,	/* pkey_alloc */
	386,	/* pkey_free */
	384,	/* pkey_mprotect */
	168,	/* poll */
	309,	/* ppoll */
	414,	/* ppoll_time64 */
	172,	/* prctl */
	180,	/* pread64 */
	333,	/* preadv */
	381,	/* preadv2 */
	339,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	365,	/* process_vm_readv */
	366,	/* process_vm_writev */
	308,	/* pselect6 */
	413,	/* pselect6_time64 */
	26,	/* ptrace */
	181,	/* pwrite64 */
	334,	/* pwritev */
	382,	/* pwritev2 */
	131,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	225,	/* readahead */
	89,	/* readdir */
	85,	/* readlink */
	305,	/* readlinkat */
	145,	/* readv */
	88,	/* reboot */
	350,	/* recv */
	351,	/* recvfrom */
	357,	/* recvmmsg */
	417,	/* recvmmsg_time64 */
	356,	/* recvmsg */
	257,	/* remap_file_pages */
	235,	/* removexattr */
	466,	/* removexattrat */
	38,	/* rename */
	302,	/* renameat */
	371,	/* renameat2 */
	286,	/* request_key */
	0,	/* restart_syscall */
	40,	/* rmdir */
	387,	/* rseq */
	471,	/* rseq_slice_yield */
	174,	/* rt_sigaction */
	176,	/* rt_sigpending */
	175,	/* rt_sigprocmask */
	178,	/* rt_sigqueueinfo */
	173,	/* rt_sigreturn */
	179,	/* rt_sigsuspend */
	177,	/* rt_sigtimedwait */
	421,	/* rt_sigtimedwait_time64 */
	335,	/* rt_tgsigqueueinfo */
	159,	/* sched_get_priority_max */
	160,	/* sched_get_priority_min */
	242,	/* sched_getaffinity */
	369,	/* sched_getattr */
	155,	/* sched_getparam */
	157,	/* sched_getscheduler */
	161,	/* sched_rr_get_interval */
	423,	/* sched_rr_get_interval_time64 */
	241,	/* sched_setaffinity */
	370,	/* sched_setattr */
	154,	/* sched_setparam */
	156,	/* sched_setscheduler */
	158,	/* sched_yield */
	372,	/* seccomp */
	394,	/* semctl */
	393,	/* semget */
	420,	/* semtimedop_time64 */
	348,	/* send */
	187,	/* sendfile */
	239,	/* sendfile64 */
	363,	/* sendmmsg */
	355,	/* sendmsg */
	349,	/* sendto */
	276,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	311,	/* set_robust_list */
	258,	/* set_tid_address */
	121,	/* setdomainname */
	139,	/* setfsgid */
	216,	/* setfsgid32 */
	138,	/* setfsuid */
	215,	/* setfsuid32 */
	46,	/* setgid */
	214,	/* setgid32 */
	81,	/* setgroups */
	206,	/* setgroups32 */
	74,	/* sethostname */
	104,	/* setitimer */
	364,	/* setns */
	57,	/* setpgid */
	97,	/* setpriority */
	71,	/* setregid */
	204,	/* setregid32 */
	170,	/* setresgid */
	210,	/* setresgid32 */
	164,	/* setresuid */
	208,	/* setresuid32 */
	70,	/* setreuid */
	203,	/* setreuid32 */
	75,	/* setrlimit */
	66,	/* setsid */
	353,	/* setsockopt */
	79,	/* settimeofday */
	23,	/* setuid */
	213,	/* setuid32 */
	226,	/* setxattr */
	463,	/* setxattrat */
	68,	/* sgetmask */
	397,	/* shmat */
	396,	/* shmctl */
	398,	/* shmdt */
	395,	/* shmget */
	352,	/* shutdown */
	67,	/* sigaction */
	186,	/* sigaltstack */
	48,	/* signal */
	321,	/* signalfd */
	327,	/* signalfd4 */
	73,	/* sigpending */
	126,	/* sigprocmask */
	119,	/* sigreturn */
	72,	/* sigsuspend */
	340,	/* socket */
	102,	/* socketcall */
	347,	/* socketpair */
	313,	/* splice */
	69,	/* ssetmask */
	106,	/* stat */
	195,	/* stat64 */
	99,	/* statfs */
	268,	/* statfs64 */
	457,	/* statmount */
	383,	/* statx */
	25,	/* stime */
	115,	/* swapoff */
	87,	/* swapon */
	83,	/* symlink */
	304,	/* symlinkat */
	36,	/* sync */
	314,	/* sync_file_range */
	388,	/* sync_file_range2 */
	362,	/* syncfs */
	135,	/* sysfs */
	116,	/* sysinfo */
	103,	/* syslog */
	315,	/* tee */
	270,	/* tgkill */
	13,	/* time */
	259,	/* timer_create */
	263,	/* timer_delete */
	262,	/* timer_getoverrun */
	261,	/* timer_gettime */
	408,	/* timer_gettime64 */
	260,	/* timer_settime */
	409,	/* timer_settime64 */
	322,	/* timerfd_create */
	326,	/* timerfd_gettime */
	410,	/* timerfd_gettime64 */
	325,	/* timerfd_settime */
	411,	/* timerfd_settime64 */
	43,	/* times */
	238,	/* tkill */
	92,	/* truncate */
	193,	/* truncate64 */
	191,	/* ugetrlimit */
	60,	/* umask */
	22,	/* umount */
	52,	/* umount2 */
	122,	/* uname */
	10,	/* unlink */
	301,	/* unlinkat */
	310,	/* unshare */
	86,	/* uselib */
	377,	/* userfaultfd */
	62,	/* ustat */
	30,	/* utime */
	320,	/* utimensat */
	412,	/* utimensat_time64 */
	271,	/* utimes */
	190,	/* vfork */
	111,	/* vhangup */
	316,	/* vmsplice */
	114,	/* wait4 */
	284,	/* waitid */
	7,	/* waitpid */
	4,	/* write */
	146,	/* writev */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__sh__)

#if defined(ALL_SYSCALLTBL) || defined(__sparc64__) || defined(__sparc__)
#if __BITS_PER_LONG != 64
static const char *const syscall_num_to_name_EM_SPARC[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "wait4",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execv",
	[12] = "chdir",
	[13] = "chown",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[17] = "brk",
	[18] = "perfctr",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "capget",
	[22] = "capset",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "vmsplice",
	[26] = "ptrace",
	[27] = "alarm",
	[28] = "sigaltstack",
	[29] = "pause",
	[30] = "utime",
	[31] = "lchown32",
	[32] = "fchown32",
	[33] = "access",
	[34] = "nice",
	[35] = "chown32",
	[36] = "sync",
	[37] = "kill",
	[38] = "stat",
	[39] = "sendfile",
	[40] = "lstat",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[44] = "getuid32",
	[45] = "umount2",
	[46] = "setgid",
	[47] = "getgid",
	[48] = "signal",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[53] = "getgid32",
	[54] = "ioctl",
	[55] = "reboot",
	[56] = "mmap2",
	[57] = "symlink",
	[58] = "readlink",
	[59] = "execve",
	[60] = "umask",
	[61] = "chroot",
	[62] = "fstat",
	[63] = "fstat64",
	[64] = "getpagesize",
	[65] = "msync",
	[66] = "vfork",
	[67] = "pread64",
	[68] = "pwrite64",
	[69] = "geteuid32",
	[70] = "getegid32",
	[71] = "mmap",
	[72] = "setreuid32",
	[73] = "munmap",
	[74] = "mprotect",
	[75] = "madvise",
	[76] = "vhangup",
	[77] = "truncate64",
	[78] = "mincore",
	[79] = "getgroups",
	[80] = "setgroups",
	[81] = "getpgrp",
	[82] = "setgroups32",
	[83] = "setitimer",
	[84] = "ftruncate64",
	[85] = "swapon",
	[86] = "getitimer",
	[87] = "setuid32",
	[88] = "sethostname",
	[89] = "setgid32",
	[90] = "dup2",
	[91] = "setfsuid32",
	[92] = "fcntl",
	[93] = "select",
	[94] = "setfsgid32",
	[95] = "fsync",
	[96] = "setpriority",
	[97] = "socket",
	[98] = "connect",
	[99] = "accept",
	[100] = "getpriority",
	[101] = "rt_sigreturn",
	[102] = "rt_sigaction",
	[103] = "rt_sigprocmask",
	[104] = "rt_sigpending",
	[105] = "rt_sigtimedwait",
	[106] = "rt_sigqueueinfo",
	[107] = "rt_sigsuspend",
	[108] = "setresuid32",
	[109] = "getresuid32",
	[110] = "setresgid32",
	[111] = "getresgid32",
	[112] = "setregid32",
	[113] = "recvmsg",
	[114] = "sendmsg",
	[115] = "getgroups32",
	[116] = "gettimeofday",
	[117] = "getrusage",
	[118] = "getsockopt",
	[119] = "getcwd",
	[120] = "readv",
	[121] = "writev",
	[122] = "settimeofday",
	[123] = "fchown",
	[124] = "fchmod",
	[125] = "recvfrom",
	[126] = "setreuid",
	[127] = "setregid",
	[128] = "rename",
	[129] = "truncate",
	[130] = "ftruncate",
	[131] = "flock",
	[132] = "lstat64",
	[133] = "sendto",
	[134] = "shutdown",
	[135] = "socketpair",
	[136] = "mkdir",
	[137] = "rmdir",
	[138] = "utimes",
	[139] = "stat64",
	[140] = "sendfile64",
	[141] = "getpeername",
	[142] = "futex",
	[143] = "gettid",
	[144] = "getrlimit",
	[145] = "setrlimit",
	[146] = "pivot_root",
	[147] = "prctl",
	[148] = "pciconfig_read",
	[149] = "pciconfig_write",
	[150] = "getsockname",
	[151] = "inotify_init",
	[152] = "inotify_add_watch",
	[153] = "poll",
	[154] = "getdents64",
	[155] = "fcntl64",
	[156] = "inotify_rm_watch",
	[157] = "statfs",
	[158] = "fstatfs",
	[159] = "umount",
	[160] = "sched_set_affinity",
	[161] = "sched_get_affinity",
	[162] = "getdomainname",
	[163] = "setdomainname",
	[165] = "quotactl",
	[166] = "set_tid_address",
	[167] = "mount",
	[168] = "ustat",
	[169] = "setxattr",
	[170] = "lsetxattr",
	[171] = "fsetxattr",
	[172] = "getxattr",
	[173] = "lgetxattr",
	[174] = "getdents",
	[175] = "setsid",
	[176] = "fchdir",
	[177] = "fgetxattr",
	[178] = "listxattr",
	[179] = "llistxattr",
	[180] = "flistxattr",
	[181] = "removexattr",
	[182] = "lremovexattr",
	[183] = "sigpending",
	[184] = "query_module",
	[185] = "setpgid",
	[186] = "fremovexattr",
	[187] = "tkill",
	[188] = "exit_group",
	[189] = "uname",
	[190] = "init_module",
	[191] = "personality",
	[192] = "remap_file_pages",
	[193] = "epoll_create",
	[194] = "epoll_ctl",
	[195] = "epoll_wait",
	[196] = "ioprio_set",
	[197] = "getppid",
	[198] = "sigaction",
	[199] = "sgetmask",
	[200] = "ssetmask",
	[201] = "sigsuspend",
	[202] = "oldlstat",
	[203] = "uselib",
	[204] = "readdir",
	[205] = "readahead",
	[206] = "socketcall",
	[207] = "syslog",
	[208] = "lookup_dcookie",
	[209] = "fadvise64",
	[210] = "fadvise64_64",
	[211] = "tgkill",
	[212] = "waitpid",
	[213] = "swapoff",
	[214] = "sysinfo",
	[215] = "ipc",
	[216] = "sigreturn",
	[217] = "clone",
	[218] = "ioprio_get",
	[219] = "adjtimex",
	[220] = "sigprocmask",
	[221] = "create_module",
	[222] = "delete_module",
	[223] = "get_kernel_syms",
	[224] = "getpgid",
	[225] = "bdflush",
	[226] = "sysfs",
	[227] = "afs_syscall",
	[228] = "setfsuid",
	[229] = "setfsgid",
	[230] = "_newselect",
	[231] = "time",
	[232] = "splice",
	[233] = "stime",
	[234] = "statfs64",
	[235] = "fstatfs64",
	[236] = "_llseek",
	[237] = "mlock",
	[238] = "munlock",
	[239] = "mlockall",
	[240] = "munlockall",
	[241] = "sched_setparam",
	[242] = "sched_getparam",
	[243] = "sched_setscheduler",
	[244] = "sched_getscheduler",
	[245] = "sched_yield",
	[246] = "sched_get_priority_max",
	[247] = "sched_get_priority_min",
	[248] = "sched_rr_get_interval",
	[249] = "nanosleep",
	[250] = "mremap",
	[251] = "_sysctl",
	[252] = "getsid",
	[253] = "fdatasync",
	[254] = "nfsservctl",
	[255] = "sync_file_range",
	[256] = "clock_settime",
	[257] = "clock_gettime",
	[258] = "clock_getres",
	[259] = "clock_nanosleep",
	[260] = "sched_getaffinity",
	[261] = "sched_setaffinity",
	[262] = "timer_settime",
	[263] = "timer_gettime",
	[264] = "timer_getoverrun",
	[265] = "timer_delete",
	[266] = "timer_create",
	[267] = "vserver",
	[268] = "io_setup",
	[269] = "io_destroy",
	[270] = "io_submit",
	[271] = "io_cancel",
	[272] = "io_getevents",
	[273] = "mq_open",
	[274] = "mq_unlink",
	[275] = "mq_timedsend",
	[276] = "mq_timedreceive",
	[277] = "mq_notify",
	[278] = "mq_getsetattr",
	[279] = "waitid",
	[280] = "tee",
	[281] = "add_key",
	[282] = "request_key",
	[283] = "keyctl",
	[284] = "openat",
	[285] = "mkdirat",
	[286] = "mknodat",
	[287] = "fchownat",
	[288] = "futimesat",
	[289] = "fstatat64",
	[290] = "unlinkat",
	[291] = "renameat",
	[292] = "linkat",
	[293] = "symlinkat",
	[294] = "readlinkat",
	[295] = "fchmodat",
	[296] = "faccessat",
	[297] = "pselect6",
	[298] = "ppoll",
	[299] = "unshare",
	[300] = "set_robust_list",
	[301] = "get_robust_list",
	[302] = "migrate_pages",
	[303] = "mbind",
	[304] = "get_mempolicy",
	[305] = "set_mempolicy",
	[306] = "kexec_load",
	[307] = "move_pages",
	[308] = "getcpu",
	[309] = "epoll_pwait",
	[310] = "utimensat",
	[311] = "signalfd",
	[312] = "timerfd_create",
	[313] = "eventfd",
	[314] = "fallocate",
	[315] = "timerfd_settime",
	[316] = "timerfd_gettime",
	[317] = "signalfd4",
	[318] = "eventfd2",
	[319] = "epoll_create1",
	[320] = "dup3",
	[321] = "pipe2",
	[322] = "inotify_init1",
	[323] = "accept4",
	[324] = "preadv",
	[325] = "pwritev",
	[326] = "rt_tgsigqueueinfo",
	[327] = "perf_event_open",
	[328] = "recvmmsg",
	[329] = "fanotify_init",
	[330] = "fanotify_mark",
	[331] = "prlimit64",
	[332] = "name_to_handle_at",
	[333] = "open_by_handle_at",
	[334] = "clock_adjtime",
	[335] = "syncfs",
	[336] = "sendmmsg",
	[337] = "setns",
	[338] = "process_vm_readv",
	[339] = "process_vm_writev",
	[340] = "kern_features",
	[341] = "kcmp",
	[342] = "finit_module",
	[343] = "sched_setattr",
	[344] = "sched_getattr",
	[345] = "renameat2",
	[346] = "seccomp",
	[347] = "getrandom",
	[348] = "memfd_create",
	[349] = "bpf",
	[350] = "execveat",
	[351] = "membarrier",
	[352] = "userfaultfd",
	[353] = "bind",
	[354] = "listen",
	[355] = "setsockopt",
	[356] = "mlock2",
	[357] = "copy_file_range",
	[358] = "preadv2",
	[359] = "pwritev2",
	[360] = "statx",
	[361] = "io_pgetevents",
	[362] = "pkey_mprotect",
	[363] = "pkey_alloc",
	[364] = "pkey_free",
	[365] = "rseq",
	[393] = "semget",
	[394] = "semctl",
	[395] = "shmget",
	[396] = "shmctl",
	[397] = "shmat",
	[398] = "shmdt",
	[399] = "msgget",
	[400] = "msgsnd",
	[401] = "msgrcv",
	[402] = "msgctl",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_SPARC[] = {
	236,	/* _llseek */
	230,	/* _newselect */
	251,	/* _sysctl */
	99,	/* accept */
	323,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	281,	/* add_key */
	219,	/* adjtimex */
	227,	/* afs_syscall */
	27,	/* alarm */
	225,	/* bdflush */
	353,	/* bind */
	349,	/* bpf */
	17,	/* brk */
	451,	/* cachestat */
	21,	/* capget */
	22,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	13,	/* chown */
	35,	/* chown32 */
	61,	/* chroot */
	334,	/* clock_adjtime */
	405,	/* clock_adjtime64 */
	258,	/* clock_getres */
	406,	/* clock_getres_time64 */
	257,	/* clock_gettime */
	403,	/* clock_gettime64 */
	259,	/* clock_nanosleep */
	407,	/* clock_nanosleep_time64 */
	256,	/* clock_settime */
	404,	/* clock_settime64 */
	217,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	98,	/* connect */
	357,	/* copy_file_range */
	8,	/* creat */
	221,	/* create_module */
	222,	/* delete_module */
	41,	/* dup */
	90,	/* dup2 */
	320,	/* dup3 */
	193,	/* epoll_create */
	319,	/* epoll_create1 */
	194,	/* epoll_ctl */
	309,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	195,	/* epoll_wait */
	313,	/* eventfd */
	318,	/* eventfd2 */
	11,	/* execv */
	59,	/* execve */
	350,	/* execveat */
	1,	/* exit */
	188,	/* exit_group */
	296,	/* faccessat */
	439,	/* faccessat2 */
	209,	/* fadvise64 */
	210,	/* fadvise64_64 */
	314,	/* fallocate */
	329,	/* fanotify_init */
	330,	/* fanotify_mark */
	176,	/* fchdir */
	124,	/* fchmod */
	295,	/* fchmodat */
	452,	/* fchmodat2 */
	123,	/* fchown */
	32,	/* fchown32 */
	287,	/* fchownat */
	92,	/* fcntl */
	155,	/* fcntl64 */
	253,	/* fdatasync */
	177,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	342,	/* finit_module */
	180,	/* flistxattr */
	131,	/* flock */
	2,	/* fork */
	186,	/* fremovexattr */
	431,	/* fsconfig */
	171,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	62,	/* fstat */
	63,	/* fstat64 */
	289,	/* fstatat64 */
	158,	/* fstatfs */
	235,	/* fstatfs64 */
	95,	/* fsync */
	130,	/* ftruncate */
	84,	/* ftruncate64 */
	142,	/* futex */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	288,	/* futimesat */
	223,	/* get_kernel_syms */
	304,	/* get_mempolicy */
	301,	/* get_robust_list */
	308,	/* getcpu */
	119,	/* getcwd */
	174,	/* getdents */
	154,	/* getdents64 */
	162,	/* getdomainname */
	50,	/* getegid */
	70,	/* getegid32 */
	49,	/* geteuid */
	69,	/* geteuid32 */
	47,	/* getgid */
	53,	/* getgid32 */
	79,	/* getgroups */
	115,	/* getgroups32 */
	86,	/* getitimer */
	64,	/* getpagesize */
	141,	/* getpeername */
	224,	/* getpgid */
	81,	/* getpgrp */
	20,	/* getpid */
	197,	/* getppid */
	100,	/* getpriority */
	347,	/* getrandom */
	111,	/* getresgid32 */
	109,	/* getresuid32 */
	144,	/* getrlimit */
	117,	/* getrusage */
	252,	/* getsid */
	150,	/* getsockname */
	118,	/* getsockopt */
	143,	/* gettid */
	116,	/* gettimeofday */
	24,	/* getuid */
	44,	/* getuid32 */
	172,	/* getxattr */
	464,	/* getxattrat */
	190,	/* init_module */
	152,	/* inotify_add_watch */
	151,	/* inotify_init */
	322,	/* inotify_init1 */
	156,	/* inotify_rm_watch */
	271,	/* io_cancel */
	269,	/* io_destroy */
	272,	/* io_getevents */
	361,	/* io_pgetevents */
	416,	/* io_pgetevents_time64 */
	268,	/* io_setup */
	270,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	218,	/* ioprio_get */
	196,	/* ioprio_set */
	215,	/* ipc */
	341,	/* kcmp */
	340,	/* kern_features */
	306,	/* kexec_load */
	283,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	31,	/* lchown32 */
	173,	/* lgetxattr */
	9,	/* link */
	292,	/* linkat */
	354,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	178,	/* listxattr */
	465,	/* listxattrat */
	179,	/* llistxattr */
	208,	/* lookup_dcookie */
	182,	/* lremovexattr */
	19,	/* lseek */
	170,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	40,	/* lstat */
	132,	/* lstat64 */
	75,	/* madvise */
	453,	/* map_shadow_stack */
	303,	/* mbind */
	351,	/* membarrier */
	348,	/* memfd_create */
	302,	/* migrate_pages */
	78,	/* mincore */
	136,	/* mkdir */
	285,	/* mkdirat */
	14,	/* mknod */
	286,	/* mknodat */
	237,	/* mlock */
	356,	/* mlock2 */
	239,	/* mlockall */
	71,	/* mmap */
	56,	/* mmap2 */
	167,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	307,	/* move_pages */
	74,	/* mprotect */
	278,	/* mq_getsetattr */
	277,	/* mq_notify */
	273,	/* mq_open */
	276,	/* mq_timedreceive */
	419,	/* mq_timedreceive_time64 */
	275,	/* mq_timedsend */
	418,	/* mq_timedsend_time64 */
	274,	/* mq_unlink */
	250,	/* mremap */
	462,	/* mseal */
	402,	/* msgctl */
	399,	/* msgget */
	401,	/* msgrcv */
	400,	/* msgsnd */
	65,	/* msync */
	238,	/* munlock */
	240,	/* munlockall */
	73,	/* munmap */
	332,	/* name_to_handle_at */
	249,	/* nanosleep */
	254,	/* nfsservctl */
	34,	/* nice */
	202,	/* oldlstat */
	5,	/* open */
	333,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	284,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	148,	/* pciconfig_read */
	149,	/* pciconfig_write */
	327,	/* perf_event_open */
	18,	/* perfctr */
	191,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	321,	/* pipe2 */
	146,	/* pivot_root */
	363,	/* pkey_alloc */
	364,	/* pkey_free */
	362,	/* pkey_mprotect */
	153,	/* poll */
	298,	/* ppoll */
	414,	/* ppoll_time64 */
	147,	/* prctl */
	67,	/* pread64 */
	324,	/* preadv */
	358,	/* preadv2 */
	331,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	338,	/* process_vm_readv */
	339,	/* process_vm_writev */
	297,	/* pselect6 */
	413,	/* pselect6_time64 */
	26,	/* ptrace */
	68,	/* pwrite64 */
	325,	/* pwritev */
	359,	/* pwritev2 */
	184,	/* query_module */
	165,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	205,	/* readahead */
	204,	/* readdir */
	58,	/* readlink */
	294,	/* readlinkat */
	120,	/* readv */
	55,	/* reboot */
	125,	/* recvfrom */
	328,	/* recvmmsg */
	417,	/* recvmmsg_time64 */
	113,	/* recvmsg */
	192,	/* remap_file_pages */
	181,	/* removexattr */
	466,	/* removexattrat */
	128,	/* rename */
	291,	/* renameat */
	345,	/* renameat2 */
	282,	/* request_key */
	0,	/* restart_syscall */
	137,	/* rmdir */
	365,	/* rseq */
	471,	/* rseq_slice_yield */
	102,	/* rt_sigaction */
	104,	/* rt_sigpending */
	103,	/* rt_sigprocmask */
	106,	/* rt_sigqueueinfo */
	101,	/* rt_sigreturn */
	107,	/* rt_sigsuspend */
	105,	/* rt_sigtimedwait */
	421,	/* rt_sigtimedwait_time64 */
	326,	/* rt_tgsigqueueinfo */
	161,	/* sched_get_affinity */
	246,	/* sched_get_priority_max */
	247,	/* sched_get_priority_min */
	260,	/* sched_getaffinity */
	344,	/* sched_getattr */
	242,	/* sched_getparam */
	244,	/* sched_getscheduler */
	248,	/* sched_rr_get_interval */
	423,	/* sched_rr_get_interval_time64 */
	160,	/* sched_set_affinity */
	261,	/* sched_setaffinity */
	343,	/* sched_setattr */
	241,	/* sched_setparam */
	243,	/* sched_setscheduler */
	245,	/* sched_yield */
	346,	/* seccomp */
	93,	/* select */
	394,	/* semctl */
	393,	/* semget */
	420,	/* semtimedop_time64 */
	39,	/* sendfile */
	140,	/* sendfile64 */
	336,	/* sendmmsg */
	114,	/* sendmsg */
	133,	/* sendto */
	305,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	300,	/* set_robust_list */
	166,	/* set_tid_address */
	163,	/* setdomainname */
	229,	/* setfsgid */
	94,	/* setfsgid32 */
	228,	/* setfsuid */
	91,	/* setfsuid32 */
	46,	/* setgid */
	89,	/* setgid32 */
	80,	/* setgroups */
	82,	/* setgroups32 */
	88,	/* sethostname */
	83,	/* setitimer */
	337,	/* setns */
	185,	/* setpgid */
	96,	/* setpriority */
	127,	/* setregid */
	112,	/* setregid32 */
	110,	/* setresgid32 */
	108,	/* setresuid32 */
	126,	/* setreuid */
	72,	/* setreuid32 */
	145,	/* setrlimit */
	175,	/* setsid */
	355,	/* setsockopt */
	122,	/* settimeofday */
	23,	/* setuid */
	87,	/* setuid32 */
	169,	/* setxattr */
	463,	/* setxattrat */
	199,	/* sgetmask */
	397,	/* shmat */
	396,	/* shmctl */
	398,	/* shmdt */
	395,	/* shmget */
	134,	/* shutdown */
	198,	/* sigaction */
	28,	/* sigaltstack */
	48,	/* signal */
	311,	/* signalfd */
	317,	/* signalfd4 */
	183,	/* sigpending */
	220,	/* sigprocmask */
	216,	/* sigreturn */
	201,	/* sigsuspend */
	97,	/* socket */
	206,	/* socketcall */
	135,	/* socketpair */
	232,	/* splice */
	200,	/* ssetmask */
	38,	/* stat */
	139,	/* stat64 */
	157,	/* statfs */
	234,	/* statfs64 */
	457,	/* statmount */
	360,	/* statx */
	233,	/* stime */
	213,	/* swapoff */
	85,	/* swapon */
	57,	/* symlink */
	293,	/* symlinkat */
	36,	/* sync */
	255,	/* sync_file_range */
	335,	/* syncfs */
	226,	/* sysfs */
	214,	/* sysinfo */
	207,	/* syslog */
	280,	/* tee */
	211,	/* tgkill */
	231,	/* time */
	266,	/* timer_create */
	265,	/* timer_delete */
	264,	/* timer_getoverrun */
	263,	/* timer_gettime */
	408,	/* timer_gettime64 */
	262,	/* timer_settime */
	409,	/* timer_settime64 */
	312,	/* timerfd_create */
	316,	/* timerfd_gettime */
	410,	/* timerfd_gettime64 */
	315,	/* timerfd_settime */
	411,	/* timerfd_settime64 */
	43,	/* times */
	187,	/* tkill */
	129,	/* truncate */
	77,	/* truncate64 */
	60,	/* umask */
	159,	/* umount */
	45,	/* umount2 */
	189,	/* uname */
	10,	/* unlink */
	290,	/* unlinkat */
	299,	/* unshare */
	203,	/* uselib */
	352,	/* userfaultfd */
	168,	/* ustat */
	30,	/* utime */
	310,	/* utimensat */
	412,	/* utimensat_time64 */
	138,	/* utimes */
	66,	/* vfork */
	76,	/* vhangup */
	25,	/* vmsplice */
	267,	/* vserver */
	7,	/* wait4 */
	279,	/* waitid */
	212,	/* waitpid */
	4,	/* write */
	121,	/* writev */
};
#else
static const char *const syscall_num_to_name_EM_SPARC[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "wait4",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execv",
	[12] = "chdir",
	[13] = "chown",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[17] = "brk",
	[18] = "perfctr",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "capget",
	[22] = "capset",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "vmsplice",
	[26] = "ptrace",
	[27] = "alarm",
	[28] = "sigaltstack",
	[29] = "pause",
	[30] = "utime",
	[33] = "access",
	[34] = "nice",
	[36] = "sync",
	[37] = "kill",
	[38] = "stat",
	[39] = "sendfile",
	[40] = "lstat",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[45] = "umount2",
	[46] = "setgid",
	[47] = "getgid",
	[48] = "signal",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[52] = "memory_ordering",
	[54] = "ioctl",
	[55] = "reboot",
	[57] = "symlink",
	[58] = "readlink",
	[59] = "execve",
	[60] = "umask",
	[61] = "chroot",
	[62] = "fstat",
	[63] = "fstat64",
	[64] = "getpagesize",
	[65] = "msync",
	[66] = "vfork",
	[67] = "pread64",
	[68] = "pwrite64",
	[71] = "mmap",
	[73] = "munmap",
	[74] = "mprotect",
	[75] = "madvise",
	[76] = "vhangup",
	[78] = "mincore",
	[79] = "getgroups",
	[80] = "setgroups",
	[81] = "getpgrp",
	[83] = "setitimer",
	[85] = "swapon",
	[86] = "getitimer",
	[88] = "sethostname",
	[90] = "dup2",
	[92] = "fcntl",
	[93] = "select",
	[95] = "fsync",
	[96] = "setpriority",
	[97] = "socket",
	[98] = "connect",
	[99] = "accept",
	[100] = "getpriority",
	[101] = "rt_sigreturn",
	[102] = "rt_sigaction",
	[103] = "rt_sigprocmask",
	[104] = "rt_sigpending",
	[105] = "rt_sigtimedwait",
	[106] = "rt_sigqueueinfo",
	[107] = "rt_sigsuspend",
	[108] = "setresuid",
	[109] = "getresuid",
	[110] = "setresgid",
	[111] = "getresgid",
	[113] = "recvmsg",
	[114] = "sendmsg",
	[116] = "gettimeofday",
	[117] = "getrusage",
	[118] = "getsockopt",
	[119] = "getcwd",
	[120] = "readv",
	[121] = "writev",
	[122] = "settimeofday",
	[123] = "fchown",
	[124] = "fchmod",
	[125] = "recvfrom",
	[126] = "setreuid",
	[127] = "setregid",
	[128] = "rename",
	[129] = "truncate",
	[130] = "ftruncate",
	[131] = "flock",
	[132] = "lstat64",
	[133] = "sendto",
	[134] = "shutdown",
	[135] = "socketpair",
	[136] = "mkdir",
	[137] = "rmdir",
	[138] = "utimes",
	[139] = "stat64",
	[140] = "sendfile64",
	[141] = "getpeername",
	[142] = "futex",
	[143] = "gettid",
	[144] = "getrlimit",
	[145] = "setrlimit",
	[146] = "pivot_root",
	[147] = "prctl",
	[148] = "pciconfig_read",
	[149] = "pciconfig_write",
	[150] = "getsockname",
	[151] = "inotify_init",
	[152] = "inotify_add_watch",
	[153] = "poll",
	[154] = "getdents64",
	[156] = "inotify_rm_watch",
	[157] = "statfs",
	[158] = "fstatfs",
	[159] = "umount",
	[160] = "sched_set_affinity",
	[161] = "sched_get_affinity",
	[162] = "getdomainname",
	[163] = "setdomainname",
	[164] = "utrap_install",
	[165] = "quotactl",
	[166] = "set_tid_address",
	[167] = "mount",
	[168] = "ustat",
	[169] = "setxattr",
	[170] = "lsetxattr",
	[171] = "fsetxattr",
	[172] = "getxattr",
	[173] = "lgetxattr",
	[174] = "getdents",
	[175] = "setsid",
	[176] = "fchdir",
	[177] = "fgetxattr",
	[178] = "listxattr",
	[179] = "llistxattr",
	[180] = "flistxattr",
	[181] = "removexattr",
	[182] = "lremovexattr",
	[183] = "sigpending",
	[184] = "query_module",
	[185] = "setpgid",
	[186] = "fremovexattr",
	[187] = "tkill",
	[188] = "exit_group",
	[189] = "uname",
	[190] = "init_module",
	[191] = "personality",
	[192] = "remap_file_pages",
	[193] = "epoll_create",
	[194] = "epoll_ctl",
	[195] = "epoll_wait",
	[196] = "ioprio_set",
	[197] = "getppid",
	[198] = "sigaction",
	[199] = "sgetmask",
	[200] = "ssetmask",
	[201] = "sigsuspend",
	[202] = "oldlstat",
	[203] = "uselib",
	[204] = "readdir",
	[205] = "readahead",
	[206] = "socketcall",
	[207] = "syslog",
	[208] = "lookup_dcookie",
	[209] = "fadvise64",
	[210] = "fadvise64_64",
	[211] = "tgkill",
	[212] = "waitpid",
	[213] = "swapoff",
	[214] = "sysinfo",
	[215] = "ipc",
	[216] = "sigreturn",
	[217] = "clone",
	[218] = "ioprio_get",
	[219] = "adjtimex",
	[220] = "sigprocmask",
	[221] = "create_module",
	[222] = "delete_module",
	[223] = "get_kernel_syms",
	[224] = "getpgid",
	[225] = "bdflush",
	[226] = "sysfs",
	[227] = "afs_syscall",
	[228] = "setfsuid",
	[229] = "setfsgid",
	[230] = "_newselect",
	[232] = "splice",
	[233] = "stime",
	[234] = "statfs64",
	[235] = "fstatfs64",
	[236] = "_llseek",
	[237] = "mlock",
	[238] = "munlock",
	[239] = "mlockall",
	[240] = "munlockall",
	[241] = "sched_setparam",
	[242] = "sched_getparam",
	[243] = "sched_setscheduler",
	[244] = "sched_getscheduler",
	[245] = "sched_yield",
	[246] = "sched_get_priority_max",
	[247] = "sched_get_priority_min",
	[248] = "sched_rr_get_interval",
	[249] = "nanosleep",
	[250] = "mremap",
	[251] = "_sysctl",
	[252] = "getsid",
	[253] = "fdatasync",
	[254] = "nfsservctl",
	[255] = "sync_file_range",
	[256] = "clock_settime",
	[257] = "clock_gettime",
	[258] = "clock_getres",
	[259] = "clock_nanosleep",
	[260] = "sched_getaffinity",
	[261] = "sched_setaffinity",
	[262] = "timer_settime",
	[263] = "timer_gettime",
	[264] = "timer_getoverrun",
	[265] = "timer_delete",
	[266] = "timer_create",
	[267] = "vserver",
	[268] = "io_setup",
	[269] = "io_destroy",
	[270] = "io_submit",
	[271] = "io_cancel",
	[272] = "io_getevents",
	[273] = "mq_open",
	[274] = "mq_unlink",
	[275] = "mq_timedsend",
	[276] = "mq_timedreceive",
	[277] = "mq_notify",
	[278] = "mq_getsetattr",
	[279] = "waitid",
	[280] = "tee",
	[281] = "add_key",
	[282] = "request_key",
	[283] = "keyctl",
	[284] = "openat",
	[285] = "mkdirat",
	[286] = "mknodat",
	[287] = "fchownat",
	[288] = "futimesat",
	[289] = "fstatat64",
	[290] = "unlinkat",
	[291] = "renameat",
	[292] = "linkat",
	[293] = "symlinkat",
	[294] = "readlinkat",
	[295] = "fchmodat",
	[296] = "faccessat",
	[297] = "pselect6",
	[298] = "ppoll",
	[299] = "unshare",
	[300] = "set_robust_list",
	[301] = "get_robust_list",
	[302] = "migrate_pages",
	[303] = "mbind",
	[304] = "get_mempolicy",
	[305] = "set_mempolicy",
	[306] = "kexec_load",
	[307] = "move_pages",
	[308] = "getcpu",
	[309] = "epoll_pwait",
	[310] = "utimensat",
	[311] = "signalfd",
	[312] = "timerfd_create",
	[313] = "eventfd",
	[314] = "fallocate",
	[315] = "timerfd_settime",
	[316] = "timerfd_gettime",
	[317] = "signalfd4",
	[318] = "eventfd2",
	[319] = "epoll_create1",
	[320] = "dup3",
	[321] = "pipe2",
	[322] = "inotify_init1",
	[323] = "accept4",
	[324] = "preadv",
	[325] = "pwritev",
	[326] = "rt_tgsigqueueinfo",
	[327] = "perf_event_open",
	[328] = "recvmmsg",
	[329] = "fanotify_init",
	[330] = "fanotify_mark",
	[331] = "prlimit64",
	[332] = "name_to_handle_at",
	[333] = "open_by_handle_at",
	[334] = "clock_adjtime",
	[335] = "syncfs",
	[336] = "sendmmsg",
	[337] = "setns",
	[338] = "process_vm_readv",
	[339] = "process_vm_writev",
	[340] = "kern_features",
	[341] = "kcmp",
	[342] = "finit_module",
	[343] = "sched_setattr",
	[344] = "sched_getattr",
	[345] = "renameat2",
	[346] = "seccomp",
	[347] = "getrandom",
	[348] = "memfd_create",
	[349] = "bpf",
	[350] = "execveat",
	[351] = "membarrier",
	[352] = "userfaultfd",
	[353] = "bind",
	[354] = "listen",
	[355] = "setsockopt",
	[356] = "mlock2",
	[357] = "copy_file_range",
	[358] = "preadv2",
	[359] = "pwritev2",
	[360] = "statx",
	[361] = "io_pgetevents",
	[362] = "pkey_mprotect",
	[363] = "pkey_alloc",
	[364] = "pkey_free",
	[365] = "rseq",
	[392] = "semtimedop",
	[393] = "semget",
	[394] = "semctl",
	[395] = "shmget",
	[396] = "shmctl",
	[397] = "shmat",
	[398] = "shmdt",
	[399] = "msgget",
	[400] = "msgsnd",
	[401] = "msgrcv",
	[402] = "msgctl",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_SPARC[] = {
	236,	/* _llseek */
	230,	/* _newselect */
	251,	/* _sysctl */
	99,	/* accept */
	323,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	281,	/* add_key */
	219,	/* adjtimex */
	227,	/* afs_syscall */
	27,	/* alarm */
	225,	/* bdflush */
	353,	/* bind */
	349,	/* bpf */
	17,	/* brk */
	451,	/* cachestat */
	21,	/* capget */
	22,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	13,	/* chown */
	61,	/* chroot */
	334,	/* clock_adjtime */
	258,	/* clock_getres */
	257,	/* clock_gettime */
	259,	/* clock_nanosleep */
	256,	/* clock_settime */
	217,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	98,	/* connect */
	357,	/* copy_file_range */
	8,	/* creat */
	221,	/* create_module */
	222,	/* delete_module */
	41,	/* dup */
	90,	/* dup2 */
	320,	/* dup3 */
	193,	/* epoll_create */
	319,	/* epoll_create1 */
	194,	/* epoll_ctl */
	309,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	195,	/* epoll_wait */
	313,	/* eventfd */
	318,	/* eventfd2 */
	11,	/* execv */
	59,	/* execve */
	350,	/* execveat */
	1,	/* exit */
	188,	/* exit_group */
	296,	/* faccessat */
	439,	/* faccessat2 */
	209,	/* fadvise64 */
	210,	/* fadvise64_64 */
	314,	/* fallocate */
	329,	/* fanotify_init */
	330,	/* fanotify_mark */
	176,	/* fchdir */
	124,	/* fchmod */
	295,	/* fchmodat */
	452,	/* fchmodat2 */
	123,	/* fchown */
	287,	/* fchownat */
	92,	/* fcntl */
	253,	/* fdatasync */
	177,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	342,	/* finit_module */
	180,	/* flistxattr */
	131,	/* flock */
	2,	/* fork */
	186,	/* fremovexattr */
	431,	/* fsconfig */
	171,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	62,	/* fstat */
	63,	/* fstat64 */
	289,	/* fstatat64 */
	158,	/* fstatfs */
	235,	/* fstatfs64 */
	95,	/* fsync */
	130,	/* ftruncate */
	142,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	288,	/* futimesat */
	223,	/* get_kernel_syms */
	304,	/* get_mempolicy */
	301,	/* get_robust_list */
	308,	/* getcpu */
	119,	/* getcwd */
	174,	/* getdents */
	154,	/* getdents64 */
	162,	/* getdomainname */
	50,	/* getegid */
	49,	/* geteuid */
	47,	/* getgid */
	79,	/* getgroups */
	86,	/* getitimer */
	64,	/* getpagesize */
	141,	/* getpeername */
	224,	/* getpgid */
	81,	/* getpgrp */
	20,	/* getpid */
	197,	/* getppid */
	100,	/* getpriority */
	347,	/* getrandom */
	111,	/* getresgid */
	109,	/* getresuid */
	144,	/* getrlimit */
	117,	/* getrusage */
	252,	/* getsid */
	150,	/* getsockname */
	118,	/* getsockopt */
	143,	/* gettid */
	116,	/* gettimeofday */
	24,	/* getuid */
	172,	/* getxattr */
	464,	/* getxattrat */
	190,	/* init_module */
	152,	/* inotify_add_watch */
	151,	/* inotify_init */
	322,	/* inotify_init1 */
	156,	/* inotify_rm_watch */
	271,	/* io_cancel */
	269,	/* io_destroy */
	272,	/* io_getevents */
	361,	/* io_pgetevents */
	268,	/* io_setup */
	270,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	218,	/* ioprio_get */
	196,	/* ioprio_set */
	215,	/* ipc */
	341,	/* kcmp */
	340,	/* kern_features */
	306,	/* kexec_load */
	283,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	173,	/* lgetxattr */
	9,	/* link */
	292,	/* linkat */
	354,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	178,	/* listxattr */
	465,	/* listxattrat */
	179,	/* llistxattr */
	208,	/* lookup_dcookie */
	182,	/* lremovexattr */
	19,	/* lseek */
	170,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	40,	/* lstat */
	132,	/* lstat64 */
	75,	/* madvise */
	453,	/* map_shadow_stack */
	303,	/* mbind */
	351,	/* membarrier */
	348,	/* memfd_create */
	52,	/* memory_ordering */
	302,	/* migrate_pages */
	78,	/* mincore */
	136,	/* mkdir */
	285,	/* mkdirat */
	14,	/* mknod */
	286,	/* mknodat */
	237,	/* mlock */
	356,	/* mlock2 */
	239,	/* mlockall */
	71,	/* mmap */
	167,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	307,	/* move_pages */
	74,	/* mprotect */
	278,	/* mq_getsetattr */
	277,	/* mq_notify */
	273,	/* mq_open */
	276,	/* mq_timedreceive */
	275,	/* mq_timedsend */
	274,	/* mq_unlink */
	250,	/* mremap */
	462,	/* mseal */
	402,	/* msgctl */
	399,	/* msgget */
	401,	/* msgrcv */
	400,	/* msgsnd */
	65,	/* msync */
	238,	/* munlock */
	240,	/* munlockall */
	73,	/* munmap */
	332,	/* name_to_handle_at */
	249,	/* nanosleep */
	254,	/* nfsservctl */
	34,	/* nice */
	202,	/* oldlstat */
	5,	/* open */
	333,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	284,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	148,	/* pciconfig_read */
	149,	/* pciconfig_write */
	327,	/* perf_event_open */
	18,	/* perfctr */
	191,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	321,	/* pipe2 */
	146,	/* pivot_root */
	363,	/* pkey_alloc */
	364,	/* pkey_free */
	362,	/* pkey_mprotect */
	153,	/* poll */
	298,	/* ppoll */
	147,	/* prctl */
	67,	/* pread64 */
	324,	/* preadv */
	358,	/* preadv2 */
	331,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	338,	/* process_vm_readv */
	339,	/* process_vm_writev */
	297,	/* pselect6 */
	26,	/* ptrace */
	68,	/* pwrite64 */
	325,	/* pwritev */
	359,	/* pwritev2 */
	184,	/* query_module */
	165,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	205,	/* readahead */
	204,	/* readdir */
	58,	/* readlink */
	294,	/* readlinkat */
	120,	/* readv */
	55,	/* reboot */
	125,	/* recvfrom */
	328,	/* recvmmsg */
	113,	/* recvmsg */
	192,	/* remap_file_pages */
	181,	/* removexattr */
	466,	/* removexattrat */
	128,	/* rename */
	291,	/* renameat */
	345,	/* renameat2 */
	282,	/* request_key */
	0,	/* restart_syscall */
	137,	/* rmdir */
	365,	/* rseq */
	471,	/* rseq_slice_yield */
	102,	/* rt_sigaction */
	104,	/* rt_sigpending */
	103,	/* rt_sigprocmask */
	106,	/* rt_sigqueueinfo */
	101,	/* rt_sigreturn */
	107,	/* rt_sigsuspend */
	105,	/* rt_sigtimedwait */
	326,	/* rt_tgsigqueueinfo */
	161,	/* sched_get_affinity */
	246,	/* sched_get_priority_max */
	247,	/* sched_get_priority_min */
	260,	/* sched_getaffinity */
	344,	/* sched_getattr */
	242,	/* sched_getparam */
	244,	/* sched_getscheduler */
	248,	/* sched_rr_get_interval */
	160,	/* sched_set_affinity */
	261,	/* sched_setaffinity */
	343,	/* sched_setattr */
	241,	/* sched_setparam */
	243,	/* sched_setscheduler */
	245,	/* sched_yield */
	346,	/* seccomp */
	93,	/* select */
	394,	/* semctl */
	393,	/* semget */
	392,	/* semtimedop */
	39,	/* sendfile */
	140,	/* sendfile64 */
	336,	/* sendmmsg */
	114,	/* sendmsg */
	133,	/* sendto */
	305,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	300,	/* set_robust_list */
	166,	/* set_tid_address */
	163,	/* setdomainname */
	229,	/* setfsgid */
	228,	/* setfsuid */
	46,	/* setgid */
	80,	/* setgroups */
	88,	/* sethostname */
	83,	/* setitimer */
	337,	/* setns */
	185,	/* setpgid */
	96,	/* setpriority */
	127,	/* setregid */
	110,	/* setresgid */
	108,	/* setresuid */
	126,	/* setreuid */
	145,	/* setrlimit */
	175,	/* setsid */
	355,	/* setsockopt */
	122,	/* settimeofday */
	23,	/* setuid */
	169,	/* setxattr */
	463,	/* setxattrat */
	199,	/* sgetmask */
	397,	/* shmat */
	396,	/* shmctl */
	398,	/* shmdt */
	395,	/* shmget */
	134,	/* shutdown */
	198,	/* sigaction */
	28,	/* sigaltstack */
	48,	/* signal */
	311,	/* signalfd */
	317,	/* signalfd4 */
	183,	/* sigpending */
	220,	/* sigprocmask */
	216,	/* sigreturn */
	201,	/* sigsuspend */
	97,	/* socket */
	206,	/* socketcall */
	135,	/* socketpair */
	232,	/* splice */
	200,	/* ssetmask */
	38,	/* stat */
	139,	/* stat64 */
	157,	/* statfs */
	234,	/* statfs64 */
	457,	/* statmount */
	360,	/* statx */
	233,	/* stime */
	213,	/* swapoff */
	85,	/* swapon */
	57,	/* symlink */
	293,	/* symlinkat */
	36,	/* sync */
	255,	/* sync_file_range */
	335,	/* syncfs */
	226,	/* sysfs */
	214,	/* sysinfo */
	207,	/* syslog */
	280,	/* tee */
	211,	/* tgkill */
	266,	/* timer_create */
	265,	/* timer_delete */
	264,	/* timer_getoverrun */
	263,	/* timer_gettime */
	262,	/* timer_settime */
	312,	/* timerfd_create */
	316,	/* timerfd_gettime */
	315,	/* timerfd_settime */
	43,	/* times */
	187,	/* tkill */
	129,	/* truncate */
	60,	/* umask */
	159,	/* umount */
	45,	/* umount2 */
	189,	/* uname */
	10,	/* unlink */
	290,	/* unlinkat */
	299,	/* unshare */
	203,	/* uselib */
	352,	/* userfaultfd */
	168,	/* ustat */
	30,	/* utime */
	310,	/* utimensat */
	138,	/* utimes */
	164,	/* utrap_install */
	66,	/* vfork */
	76,	/* vhangup */
	25,	/* vmsplice */
	267,	/* vserver */
	7,	/* wait4 */
	279,	/* waitid */
	212,	/* waitpid */
	4,	/* write */
	121,	/* writev */
};
#endif //__BITS_PER_LONG != 64
#endif // defined(ALL_SYSCALLTBL) || defined(__sparc64__) || defined(__sparc__)

#if defined(ALL_SYSCALLTBL) || defined(__i386__) || defined(__x86_64__)
static const char *const syscall_num_to_name_EM_386[] = {
	[0] = "restart_syscall",
	[1] = "exit",
	[2] = "fork",
	[3] = "read",
	[4] = "write",
	[5] = "open",
	[6] = "close",
	[7] = "waitpid",
	[8] = "creat",
	[9] = "link",
	[10] = "unlink",
	[11] = "execve",
	[12] = "chdir",
	[13] = "time",
	[14] = "mknod",
	[15] = "chmod",
	[16] = "lchown",
	[17] = "break",
	[18] = "oldstat",
	[19] = "lseek",
	[20] = "getpid",
	[21] = "mount",
	[22] = "umount",
	[23] = "setuid",
	[24] = "getuid",
	[25] = "stime",
	[26] = "ptrace",
	[27] = "alarm",
	[28] = "oldfstat",
	[29] = "pause",
	[30] = "utime",
	[31] = "stty",
	[32] = "gtty",
	[33] = "access",
	[34] = "nice",
	[35] = "ftime",
	[36] = "sync",
	[37] = "kill",
	[38] = "rename",
	[39] = "mkdir",
	[40] = "rmdir",
	[41] = "dup",
	[42] = "pipe",
	[43] = "times",
	[44] = "prof",
	[45] = "brk",
	[46] = "setgid",
	[47] = "getgid",
	[48] = "signal",
	[49] = "geteuid",
	[50] = "getegid",
	[51] = "acct",
	[52] = "umount2",
	[53] = "lock",
	[54] = "ioctl",
	[55] = "fcntl",
	[56] = "mpx",
	[57] = "setpgid",
	[58] = "ulimit",
	[59] = "oldolduname",
	[60] = "umask",
	[61] = "chroot",
	[62] = "ustat",
	[63] = "dup2",
	[64] = "getppid",
	[65] = "getpgrp",
	[66] = "setsid",
	[67] = "sigaction",
	[68] = "sgetmask",
	[69] = "ssetmask",
	[70] = "setreuid",
	[71] = "setregid",
	[72] = "sigsuspend",
	[73] = "sigpending",
	[74] = "sethostname",
	[75] = "setrlimit",
	[76] = "getrlimit",
	[77] = "getrusage",
	[78] = "gettimeofday",
	[79] = "settimeofday",
	[80] = "getgroups",
	[81] = "setgroups",
	[82] = "select",
	[83] = "symlink",
	[84] = "oldlstat",
	[85] = "readlink",
	[86] = "uselib",
	[87] = "swapon",
	[88] = "reboot",
	[89] = "readdir",
	[90] = "mmap",
	[91] = "munmap",
	[92] = "truncate",
	[93] = "ftruncate",
	[94] = "fchmod",
	[95] = "fchown",
	[96] = "getpriority",
	[97] = "setpriority",
	[98] = "profil",
	[99] = "statfs",
	[100] = "fstatfs",
	[101] = "ioperm",
	[102] = "socketcall",
	[103] = "syslog",
	[104] = "setitimer",
	[105] = "getitimer",
	[106] = "stat",
	[107] = "lstat",
	[108] = "fstat",
	[109] = "olduname",
	[110] = "iopl",
	[111] = "vhangup",
	[112] = "idle",
	[113] = "vm86old",
	[114] = "wait4",
	[115] = "swapoff",
	[116] = "sysinfo",
	[117] = "ipc",
	[118] = "fsync",
	[119] = "sigreturn",
	[120] = "clone",
	[121] = "setdomainname",
	[122] = "uname",
	[123] = "modify_ldt",
	[124] = "adjtimex",
	[125] = "mprotect",
	[126] = "sigprocmask",
	[127] = "create_module",
	[128] = "init_module",
	[129] = "delete_module",
	[130] = "get_kernel_syms",
	[131] = "quotactl",
	[132] = "getpgid",
	[133] = "fchdir",
	[134] = "bdflush",
	[135] = "sysfs",
	[136] = "personality",
	[137] = "afs_syscall",
	[138] = "setfsuid",
	[139] = "setfsgid",
	[140] = "_llseek",
	[141] = "getdents",
	[142] = "_newselect",
	[143] = "flock",
	[144] = "msync",
	[145] = "readv",
	[146] = "writev",
	[147] = "getsid",
	[148] = "fdatasync",
	[149] = "_sysctl",
	[150] = "mlock",
	[151] = "munlock",
	[152] = "mlockall",
	[153] = "munlockall",
	[154] = "sched_setparam",
	[155] = "sched_getparam",
	[156] = "sched_setscheduler",
	[157] = "sched_getscheduler",
	[158] = "sched_yield",
	[159] = "sched_get_priority_max",
	[160] = "sched_get_priority_min",
	[161] = "sched_rr_get_interval",
	[162] = "nanosleep",
	[163] = "mremap",
	[164] = "setresuid",
	[165] = "getresuid",
	[166] = "vm86",
	[167] = "query_module",
	[168] = "poll",
	[169] = "nfsservctl",
	[170] = "setresgid",
	[171] = "getresgid",
	[172] = "prctl",
	[173] = "rt_sigreturn",
	[174] = "rt_sigaction",
	[175] = "rt_sigprocmask",
	[176] = "rt_sigpending",
	[177] = "rt_sigtimedwait",
	[178] = "rt_sigqueueinfo",
	[179] = "rt_sigsuspend",
	[180] = "pread64",
	[181] = "pwrite64",
	[182] = "chown",
	[183] = "getcwd",
	[184] = "capget",
	[185] = "capset",
	[186] = "sigaltstack",
	[187] = "sendfile",
	[188] = "getpmsg",
	[189] = "putpmsg",
	[190] = "vfork",
	[191] = "ugetrlimit",
	[192] = "mmap2",
	[193] = "truncate64",
	[194] = "ftruncate64",
	[195] = "stat64",
	[196] = "lstat64",
	[197] = "fstat64",
	[198] = "lchown32",
	[199] = "getuid32",
	[200] = "getgid32",
	[201] = "geteuid32",
	[202] = "getegid32",
	[203] = "setreuid32",
	[204] = "setregid32",
	[205] = "getgroups32",
	[206] = "setgroups32",
	[207] = "fchown32",
	[208] = "setresuid32",
	[209] = "getresuid32",
	[210] = "setresgid32",
	[211] = "getresgid32",
	[212] = "chown32",
	[213] = "setuid32",
	[214] = "setgid32",
	[215] = "setfsuid32",
	[216] = "setfsgid32",
	[217] = "pivot_root",
	[218] = "mincore",
	[219] = "madvise",
	[220] = "getdents64",
	[221] = "fcntl64",
	[224] = "gettid",
	[225] = "readahead",
	[226] = "setxattr",
	[227] = "lsetxattr",
	[228] = "fsetxattr",
	[229] = "getxattr",
	[230] = "lgetxattr",
	[231] = "fgetxattr",
	[232] = "listxattr",
	[233] = "llistxattr",
	[234] = "flistxattr",
	[235] = "removexattr",
	[236] = "lremovexattr",
	[237] = "fremovexattr",
	[238] = "tkill",
	[239] = "sendfile64",
	[240] = "futex",
	[241] = "sched_setaffinity",
	[242] = "sched_getaffinity",
	[243] = "set_thread_area",
	[244] = "get_thread_area",
	[245] = "io_setup",
	[246] = "io_destroy",
	[247] = "io_getevents",
	[248] = "io_submit",
	[249] = "io_cancel",
	[250] = "fadvise64",
	[252] = "exit_group",
	[253] = "lookup_dcookie",
	[254] = "epoll_create",
	[255] = "epoll_ctl",
	[256] = "epoll_wait",
	[257] = "remap_file_pages",
	[258] = "set_tid_address",
	[259] = "timer_create",
	[260] = "timer_settime",
	[261] = "timer_gettime",
	[262] = "timer_getoverrun",
	[263] = "timer_delete",
	[264] = "clock_settime",
	[265] = "clock_gettime",
	[266] = "clock_getres",
	[267] = "clock_nanosleep",
	[268] = "statfs64",
	[269] = "fstatfs64",
	[270] = "tgkill",
	[271] = "utimes",
	[272] = "fadvise64_64",
	[273] = "vserver",
	[274] = "mbind",
	[275] = "get_mempolicy",
	[276] = "set_mempolicy",
	[277] = "mq_open",
	[278] = "mq_unlink",
	[279] = "mq_timedsend",
	[280] = "mq_timedreceive",
	[281] = "mq_notify",
	[282] = "mq_getsetattr",
	[283] = "kexec_load",
	[284] = "waitid",
	[286] = "add_key",
	[287] = "request_key",
	[288] = "keyctl",
	[289] = "ioprio_set",
	[290] = "ioprio_get",
	[291] = "inotify_init",
	[292] = "inotify_add_watch",
	[293] = "inotify_rm_watch",
	[294] = "migrate_pages",
	[295] = "openat",
	[296] = "mkdirat",
	[297] = "mknodat",
	[298] = "fchownat",
	[299] = "futimesat",
	[300] = "fstatat64",
	[301] = "unlinkat",
	[302] = "renameat",
	[303] = "linkat",
	[304] = "symlinkat",
	[305] = "readlinkat",
	[306] = "fchmodat",
	[307] = "faccessat",
	[308] = "pselect6",
	[309] = "ppoll",
	[310] = "unshare",
	[311] = "set_robust_list",
	[312] = "get_robust_list",
	[313] = "splice",
	[314] = "sync_file_range",
	[315] = "tee",
	[316] = "vmsplice",
	[317] = "move_pages",
	[318] = "getcpu",
	[319] = "epoll_pwait",
	[320] = "utimensat",
	[321] = "signalfd",
	[322] = "timerfd_create",
	[323] = "eventfd",
	[324] = "fallocate",
	[325] = "timerfd_settime",
	[326] = "timerfd_gettime",
	[327] = "signalfd4",
	[328] = "eventfd2",
	[329] = "epoll_create1",
	[330] = "dup3",
	[331] = "pipe2",
	[332] = "inotify_init1",
	[333] = "preadv",
	[334] = "pwritev",
	[335] = "rt_tgsigqueueinfo",
	[336] = "perf_event_open",
	[337] = "recvmmsg",
	[338] = "fanotify_init",
	[339] = "fanotify_mark",
	[340] = "prlimit64",
	[341] = "name_to_handle_at",
	[342] = "open_by_handle_at",
	[343] = "clock_adjtime",
	[344] = "syncfs",
	[345] = "sendmmsg",
	[346] = "setns",
	[347] = "process_vm_readv",
	[348] = "process_vm_writev",
	[349] = "kcmp",
	[350] = "finit_module",
	[351] = "sched_setattr",
	[352] = "sched_getattr",
	[353] = "renameat2",
	[354] = "seccomp",
	[355] = "getrandom",
	[356] = "memfd_create",
	[357] = "bpf",
	[358] = "execveat",
	[359] = "socket",
	[360] = "socketpair",
	[361] = "bind",
	[362] = "connect",
	[363] = "listen",
	[364] = "accept4",
	[365] = "getsockopt",
	[366] = "setsockopt",
	[367] = "getsockname",
	[368] = "getpeername",
	[369] = "sendto",
	[370] = "sendmsg",
	[371] = "recvfrom",
	[372] = "recvmsg",
	[373] = "shutdown",
	[374] = "userfaultfd",
	[375] = "membarrier",
	[376] = "mlock2",
	[377] = "copy_file_range",
	[378] = "preadv2",
	[379] = "pwritev2",
	[380] = "pkey_mprotect",
	[381] = "pkey_alloc",
	[382] = "pkey_free",
	[383] = "statx",
	[384] = "arch_prctl",
	[385] = "io_pgetevents",
	[386] = "rseq",
	[393] = "semget",
	[394] = "semctl",
	[395] = "shmget",
	[396] = "shmctl",
	[397] = "shmat",
	[398] = "shmdt",
	[399] = "msgget",
	[400] = "msgsnd",
	[401] = "msgrcv",
	[402] = "msgctl",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[447] = "memfd_secret",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_386[] = {
	140,	/* _llseek */
	142,	/* _newselect */
	149,	/* _sysctl */
	364,	/* accept4 */
	33,	/* access */
	51,	/* acct */
	286,	/* add_key */
	124,	/* adjtimex */
	137,	/* afs_syscall */
	27,	/* alarm */
	384,	/* arch_prctl */
	134,	/* bdflush */
	361,	/* bind */
	357,	/* bpf */
	17,	/* break */
	45,	/* brk */
	451,	/* cachestat */
	184,	/* capget */
	185,	/* capset */
	12,	/* chdir */
	15,	/* chmod */
	182,	/* chown */
	212,	/* chown32 */
	61,	/* chroot */
	343,	/* clock_adjtime */
	405,	/* clock_adjtime64 */
	266,	/* clock_getres */
	406,	/* clock_getres_time64 */
	265,	/* clock_gettime */
	403,	/* clock_gettime64 */
	267,	/* clock_nanosleep */
	407,	/* clock_nanosleep_time64 */
	264,	/* clock_settime */
	404,	/* clock_settime64 */
	120,	/* clone */
	435,	/* clone3 */
	6,	/* close */
	436,	/* close_range */
	362,	/* connect */
	377,	/* copy_file_range */
	8,	/* creat */
	127,	/* create_module */
	129,	/* delete_module */
	41,	/* dup */
	63,	/* dup2 */
	330,	/* dup3 */
	254,	/* epoll_create */
	329,	/* epoll_create1 */
	255,	/* epoll_ctl */
	319,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	256,	/* epoll_wait */
	323,	/* eventfd */
	328,	/* eventfd2 */
	11,	/* execve */
	358,	/* execveat */
	1,	/* exit */
	252,	/* exit_group */
	307,	/* faccessat */
	439,	/* faccessat2 */
	250,	/* fadvise64 */
	272,	/* fadvise64_64 */
	324,	/* fallocate */
	338,	/* fanotify_init */
	339,	/* fanotify_mark */
	133,	/* fchdir */
	94,	/* fchmod */
	306,	/* fchmodat */
	452,	/* fchmodat2 */
	95,	/* fchown */
	207,	/* fchown32 */
	298,	/* fchownat */
	55,	/* fcntl */
	221,	/* fcntl64 */
	148,	/* fdatasync */
	231,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	350,	/* finit_module */
	234,	/* flistxattr */
	143,	/* flock */
	2,	/* fork */
	237,	/* fremovexattr */
	431,	/* fsconfig */
	228,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	108,	/* fstat */
	197,	/* fstat64 */
	300,	/* fstatat64 */
	100,	/* fstatfs */
	269,	/* fstatfs64 */
	118,	/* fsync */
	35,	/* ftime */
	93,	/* ftruncate */
	194,	/* ftruncate64 */
	240,	/* futex */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	299,	/* futimesat */
	130,	/* get_kernel_syms */
	275,	/* get_mempolicy */
	312,	/* get_robust_list */
	244,	/* get_thread_area */
	318,	/* getcpu */
	183,	/* getcwd */
	141,	/* getdents */
	220,	/* getdents64 */
	50,	/* getegid */
	202,	/* getegid32 */
	49,	/* geteuid */
	201,	/* geteuid32 */
	47,	/* getgid */
	200,	/* getgid32 */
	80,	/* getgroups */
	205,	/* getgroups32 */
	105,	/* getitimer */
	368,	/* getpeername */
	132,	/* getpgid */
	65,	/* getpgrp */
	20,	/* getpid */
	188,	/* getpmsg */
	64,	/* getppid */
	96,	/* getpriority */
	355,	/* getrandom */
	171,	/* getresgid */
	211,	/* getresgid32 */
	165,	/* getresuid */
	209,	/* getresuid32 */
	76,	/* getrlimit */
	77,	/* getrusage */
	147,	/* getsid */
	367,	/* getsockname */
	365,	/* getsockopt */
	224,	/* gettid */
	78,	/* gettimeofday */
	24,	/* getuid */
	199,	/* getuid32 */
	229,	/* getxattr */
	464,	/* getxattrat */
	32,	/* gtty */
	112,	/* idle */
	128,	/* init_module */
	292,	/* inotify_add_watch */
	291,	/* inotify_init */
	332,	/* inotify_init1 */
	293,	/* inotify_rm_watch */
	249,	/* io_cancel */
	246,	/* io_destroy */
	247,	/* io_getevents */
	385,	/* io_pgetevents */
	416,	/* io_pgetevents_time64 */
	245,	/* io_setup */
	248,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	54,	/* ioctl */
	101,	/* ioperm */
	110,	/* iopl */
	290,	/* ioprio_get */
	289,	/* ioprio_set */
	117,	/* ipc */
	349,	/* kcmp */
	283,	/* kexec_load */
	288,	/* keyctl */
	37,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	16,	/* lchown */
	198,	/* lchown32 */
	230,	/* lgetxattr */
	9,	/* link */
	303,	/* linkat */
	363,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	232,	/* listxattr */
	465,	/* listxattrat */
	233,	/* llistxattr */
	53,	/* lock */
	253,	/* lookup_dcookie */
	236,	/* lremovexattr */
	19,	/* lseek */
	227,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	107,	/* lstat */
	196,	/* lstat64 */
	219,	/* madvise */
	453,	/* map_shadow_stack */
	274,	/* mbind */
	375,	/* membarrier */
	356,	/* memfd_create */
	447,	/* memfd_secret */
	294,	/* migrate_pages */
	218,	/* mincore */
	39,	/* mkdir */
	296,	/* mkdirat */
	14,	/* mknod */
	297,	/* mknodat */
	150,	/* mlock */
	376,	/* mlock2 */
	152,	/* mlockall */
	90,	/* mmap */
	192,	/* mmap2 */
	123,	/* modify_ldt */
	21,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	317,	/* move_pages */
	125,	/* mprotect */
	56,	/* mpx */
	282,	/* mq_getsetattr */
	281,	/* mq_notify */
	277,	/* mq_open */
	280,	/* mq_timedreceive */
	419,	/* mq_timedreceive_time64 */
	279,	/* mq_timedsend */
	418,	/* mq_timedsend_time64 */
	278,	/* mq_unlink */
	163,	/* mremap */
	462,	/* mseal */
	402,	/* msgctl */
	399,	/* msgget */
	401,	/* msgrcv */
	400,	/* msgsnd */
	144,	/* msync */
	151,	/* munlock */
	153,	/* munlockall */
	91,	/* munmap */
	341,	/* name_to_handle_at */
	162,	/* nanosleep */
	169,	/* nfsservctl */
	34,	/* nice */
	28,	/* oldfstat */
	84,	/* oldlstat */
	59,	/* oldolduname */
	18,	/* oldstat */
	109,	/* olduname */
	5,	/* open */
	342,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	295,	/* openat */
	437,	/* openat2 */
	29,	/* pause */
	336,	/* perf_event_open */
	136,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	42,	/* pipe */
	331,	/* pipe2 */
	217,	/* pivot_root */
	381,	/* pkey_alloc */
	382,	/* pkey_free */
	380,	/* pkey_mprotect */
	168,	/* poll */
	309,	/* ppoll */
	414,	/* ppoll_time64 */
	172,	/* prctl */
	180,	/* pread64 */
	333,	/* preadv */
	378,	/* preadv2 */
	340,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	347,	/* process_vm_readv */
	348,	/* process_vm_writev */
	44,	/* prof */
	98,	/* profil */
	308,	/* pselect6 */
	413,	/* pselect6_time64 */
	26,	/* ptrace */
	189,	/* putpmsg */
	181,	/* pwrite64 */
	334,	/* pwritev */
	379,	/* pwritev2 */
	167,	/* query_module */
	131,	/* quotactl */
	443,	/* quotactl_fd */
	3,	/* read */
	225,	/* readahead */
	89,	/* readdir */
	85,	/* readlink */
	305,	/* readlinkat */
	145,	/* readv */
	88,	/* reboot */
	371,	/* recvfrom */
	337,	/* recvmmsg */
	417,	/* recvmmsg_time64 */
	372,	/* recvmsg */
	257,	/* remap_file_pages */
	235,	/* removexattr */
	466,	/* removexattrat */
	38,	/* rename */
	302,	/* renameat */
	353,	/* renameat2 */
	287,	/* request_key */
	0,	/* restart_syscall */
	40,	/* rmdir */
	386,	/* rseq */
	471,	/* rseq_slice_yield */
	174,	/* rt_sigaction */
	176,	/* rt_sigpending */
	175,	/* rt_sigprocmask */
	178,	/* rt_sigqueueinfo */
	173,	/* rt_sigreturn */
	179,	/* rt_sigsuspend */
	177,	/* rt_sigtimedwait */
	421,	/* rt_sigtimedwait_time64 */
	335,	/* rt_tgsigqueueinfo */
	159,	/* sched_get_priority_max */
	160,	/* sched_get_priority_min */
	242,	/* sched_getaffinity */
	352,	/* sched_getattr */
	155,	/* sched_getparam */
	157,	/* sched_getscheduler */
	161,	/* sched_rr_get_interval */
	423,	/* sched_rr_get_interval_time64 */
	241,	/* sched_setaffinity */
	351,	/* sched_setattr */
	154,	/* sched_setparam */
	156,	/* sched_setscheduler */
	158,	/* sched_yield */
	354,	/* seccomp */
	82,	/* select */
	394,	/* semctl */
	393,	/* semget */
	420,	/* semtimedop_time64 */
	187,	/* sendfile */
	239,	/* sendfile64 */
	345,	/* sendmmsg */
	370,	/* sendmsg */
	369,	/* sendto */
	276,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	311,	/* set_robust_list */
	243,	/* set_thread_area */
	258,	/* set_tid_address */
	121,	/* setdomainname */
	139,	/* setfsgid */
	216,	/* setfsgid32 */
	138,	/* setfsuid */
	215,	/* setfsuid32 */
	46,	/* setgid */
	214,	/* setgid32 */
	81,	/* setgroups */
	206,	/* setgroups32 */
	74,	/* sethostname */
	104,	/* setitimer */
	346,	/* setns */
	57,	/* setpgid */
	97,	/* setpriority */
	71,	/* setregid */
	204,	/* setregid32 */
	170,	/* setresgid */
	210,	/* setresgid32 */
	164,	/* setresuid */
	208,	/* setresuid32 */
	70,	/* setreuid */
	203,	/* setreuid32 */
	75,	/* setrlimit */
	66,	/* setsid */
	366,	/* setsockopt */
	79,	/* settimeofday */
	23,	/* setuid */
	213,	/* setuid32 */
	226,	/* setxattr */
	463,	/* setxattrat */
	68,	/* sgetmask */
	397,	/* shmat */
	396,	/* shmctl */
	398,	/* shmdt */
	395,	/* shmget */
	373,	/* shutdown */
	67,	/* sigaction */
	186,	/* sigaltstack */
	48,	/* signal */
	321,	/* signalfd */
	327,	/* signalfd4 */
	73,	/* sigpending */
	126,	/* sigprocmask */
	119,	/* sigreturn */
	72,	/* sigsuspend */
	359,	/* socket */
	102,	/* socketcall */
	360,	/* socketpair */
	313,	/* splice */
	69,	/* ssetmask */
	106,	/* stat */
	195,	/* stat64 */
	99,	/* statfs */
	268,	/* statfs64 */
	457,	/* statmount */
	383,	/* statx */
	25,	/* stime */
	31,	/* stty */
	115,	/* swapoff */
	87,	/* swapon */
	83,	/* symlink */
	304,	/* symlinkat */
	36,	/* sync */
	314,	/* sync_file_range */
	344,	/* syncfs */
	135,	/* sysfs */
	116,	/* sysinfo */
	103,	/* syslog */
	315,	/* tee */
	270,	/* tgkill */
	13,	/* time */
	259,	/* timer_create */
	263,	/* timer_delete */
	262,	/* timer_getoverrun */
	261,	/* timer_gettime */
	408,	/* timer_gettime64 */
	260,	/* timer_settime */
	409,	/* timer_settime64 */
	322,	/* timerfd_create */
	326,	/* timerfd_gettime */
	410,	/* timerfd_gettime64 */
	325,	/* timerfd_settime */
	411,	/* timerfd_settime64 */
	43,	/* times */
	238,	/* tkill */
	92,	/* truncate */
	193,	/* truncate64 */
	191,	/* ugetrlimit */
	58,	/* ulimit */
	60,	/* umask */
	22,	/* umount */
	52,	/* umount2 */
	122,	/* uname */
	10,	/* unlink */
	301,	/* unlinkat */
	310,	/* unshare */
	86,	/* uselib */
	374,	/* userfaultfd */
	62,	/* ustat */
	30,	/* utime */
	320,	/* utimensat */
	412,	/* utimensat_time64 */
	271,	/* utimes */
	190,	/* vfork */
	111,	/* vhangup */
	166,	/* vm86 */
	113,	/* vm86old */
	316,	/* vmsplice */
	273,	/* vserver */
	114,	/* wait4 */
	284,	/* waitid */
	7,	/* waitpid */
	4,	/* write */
	146,	/* writev */
};
static const char *const syscall_num_to_name_EM_X86_64[] = {
	[0] = "read",
	[1] = "write",
	[2] = "open",
	[3] = "close",
	[4] = "stat",
	[5] = "fstat",
	[6] = "lstat",
	[7] = "poll",
	[8] = "lseek",
	[9] = "mmap",
	[10] = "mprotect",
	[11] = "munmap",
	[12] = "brk",
	[13] = "rt_sigaction",
	[14] = "rt_sigprocmask",
	[15] = "rt_sigreturn",
	[16] = "ioctl",
	[17] = "pread64",
	[18] = "pwrite64",
	[19] = "readv",
	[20] = "writev",
	[21] = "access",
	[22] = "pipe",
	[23] = "select",
	[24] = "sched_yield",
	[25] = "mremap",
	[26] = "msync",
	[27] = "mincore",
	[28] = "madvise",
	[29] = "shmget",
	[30] = "shmat",
	[31] = "shmctl",
	[32] = "dup",
	[33] = "dup2",
	[34] = "pause",
	[35] = "nanosleep",
	[36] = "getitimer",
	[37] = "alarm",
	[38] = "setitimer",
	[39] = "getpid",
	[40] = "sendfile",
	[41] = "socket",
	[42] = "connect",
	[43] = "accept",
	[44] = "sendto",
	[45] = "recvfrom",
	[46] = "sendmsg",
	[47] = "recvmsg",
	[48] = "shutdown",
	[49] = "bind",
	[50] = "listen",
	[51] = "getsockname",
	[52] = "getpeername",
	[53] = "socketpair",
	[54] = "setsockopt",
	[55] = "getsockopt",
	[56] = "clone",
	[57] = "fork",
	[58] = "vfork",
	[59] = "execve",
	[60] = "exit",
	[61] = "wait4",
	[62] = "kill",
	[63] = "uname",
	[64] = "semget",
	[65] = "semop",
	[66] = "semctl",
	[67] = "shmdt",
	[68] = "msgget",
	[69] = "msgsnd",
	[70] = "msgrcv",
	[71] = "msgctl",
	[72] = "fcntl",
	[73] = "flock",
	[74] = "fsync",
	[75] = "fdatasync",
	[76] = "truncate",
	[77] = "ftruncate",
	[78] = "getdents",
	[79] = "getcwd",
	[80] = "chdir",
	[81] = "fchdir",
	[82] = "rename",
	[83] = "mkdir",
	[84] = "rmdir",
	[85] = "creat",
	[86] = "link",
	[87] = "unlink",
	[88] = "symlink",
	[89] = "readlink",
	[90] = "chmod",
	[91] = "fchmod",
	[92] = "chown",
	[93] = "fchown",
	[94] = "lchown",
	[95] = "umask",
	[96] = "gettimeofday",
	[97] = "getrlimit",
	[98] = "getrusage",
	[99] = "sysinfo",
	[100] = "times",
	[101] = "ptrace",
	[102] = "getuid",
	[103] = "syslog",
	[104] = "getgid",
	[105] = "setuid",
	[106] = "setgid",
	[107] = "geteuid",
	[108] = "getegid",
	[109] = "setpgid",
	[110] = "getppid",
	[111] = "getpgrp",
	[112] = "setsid",
	[113] = "setreuid",
	[114] = "setregid",
	[115] = "getgroups",
	[116] = "setgroups",
	[117] = "setresuid",
	[118] = "getresuid",
	[119] = "setresgid",
	[120] = "getresgid",
	[121] = "getpgid",
	[122] = "setfsuid",
	[123] = "setfsgid",
	[124] = "getsid",
	[125] = "capget",
	[126] = "capset",
	[127] = "rt_sigpending",
	[128] = "rt_sigtimedwait",
	[129] = "rt_sigqueueinfo",
	[130] = "rt_sigsuspend",
	[131] = "sigaltstack",
	[132] = "utime",
	[133] = "mknod",
	[134] = "uselib",
	[135] = "personality",
	[136] = "ustat",
	[137] = "statfs",
	[138] = "fstatfs",
	[139] = "sysfs",
	[140] = "getpriority",
	[141] = "setpriority",
	[142] = "sched_setparam",
	[143] = "sched_getparam",
	[144] = "sched_setscheduler",
	[145] = "sched_getscheduler",
	[146] = "sched_get_priority_max",
	[147] = "sched_get_priority_min",
	[148] = "sched_rr_get_interval",
	[149] = "mlock",
	[150] = "munlock",
	[151] = "mlockall",
	[152] = "munlockall",
	[153] = "vhangup",
	[154] = "modify_ldt",
	[155] = "pivot_root",
	[156] = "_sysctl",
	[157] = "prctl",
	[158] = "arch_prctl",
	[159] = "adjtimex",
	[160] = "setrlimit",
	[161] = "chroot",
	[162] = "sync",
	[163] = "acct",
	[164] = "settimeofday",
	[165] = "mount",
	[166] = "umount2",
	[167] = "swapon",
	[168] = "swapoff",
	[169] = "reboot",
	[170] = "sethostname",
	[171] = "setdomainname",
	[172] = "iopl",
	[173] = "ioperm",
	[174] = "create_module",
	[175] = "init_module",
	[176] = "delete_module",
	[177] = "get_kernel_syms",
	[178] = "query_module",
	[179] = "quotactl",
	[180] = "nfsservctl",
	[181] = "getpmsg",
	[182] = "putpmsg",
	[183] = "afs_syscall",
	[184] = "tuxcall",
	[185] = "security",
	[186] = "gettid",
	[187] = "readahead",
	[188] = "setxattr",
	[189] = "lsetxattr",
	[190] = "fsetxattr",
	[191] = "getxattr",
	[192] = "lgetxattr",
	[193] = "fgetxattr",
	[194] = "listxattr",
	[195] = "llistxattr",
	[196] = "flistxattr",
	[197] = "removexattr",
	[198] = "lremovexattr",
	[199] = "fremovexattr",
	[200] = "tkill",
	[201] = "time",
	[202] = "futex",
	[203] = "sched_setaffinity",
	[204] = "sched_getaffinity",
	[205] = "set_thread_area",
	[206] = "io_setup",
	[207] = "io_destroy",
	[208] = "io_getevents",
	[209] = "io_submit",
	[210] = "io_cancel",
	[211] = "get_thread_area",
	[212] = "lookup_dcookie",
	[213] = "epoll_create",
	[214] = "epoll_ctl_old",
	[215] = "epoll_wait_old",
	[216] = "remap_file_pages",
	[217] = "getdents64",
	[218] = "set_tid_address",
	[219] = "restart_syscall",
	[220] = "semtimedop",
	[221] = "fadvise64",
	[222] = "timer_create",
	[223] = "timer_settime",
	[224] = "timer_gettime",
	[225] = "timer_getoverrun",
	[226] = "timer_delete",
	[227] = "clock_settime",
	[228] = "clock_gettime",
	[229] = "clock_getres",
	[230] = "clock_nanosleep",
	[231] = "exit_group",
	[232] = "epoll_wait",
	[233] = "epoll_ctl",
	[234] = "tgkill",
	[235] = "utimes",
	[236] = "vserver",
	[237] = "mbind",
	[238] = "set_mempolicy",
	[239] = "get_mempolicy",
	[240] = "mq_open",
	[241] = "mq_unlink",
	[242] = "mq_timedsend",
	[243] = "mq_timedreceive",
	[244] = "mq_notify",
	[245] = "mq_getsetattr",
	[246] = "kexec_load",
	[247] = "waitid",
	[248] = "add_key",
	[249] = "request_key",
	[250] = "keyctl",
	[251] = "ioprio_set",
	[252] = "ioprio_get",
	[253] = "inotify_init",
	[254] = "inotify_add_watch",
	[255] = "inotify_rm_watch",
	[256] = "migrate_pages",
	[257] = "openat",
	[258] = "mkdirat",
	[259] = "mknodat",
	[260] = "fchownat",
	[261] = "futimesat",
	[262] = "newfstatat",
	[263] = "unlinkat",
	[264] = "renameat",
	[265] = "linkat",
	[266] = "symlinkat",
	[267] = "readlinkat",
	[268] = "fchmodat",
	[269] = "faccessat",
	[270] = "pselect6",
	[271] = "ppoll",
	[272] = "unshare",
	[273] = "set_robust_list",
	[274] = "get_robust_list",
	[275] = "splice",
	[276] = "tee",
	[277] = "sync_file_range",
	[278] = "vmsplice",
	[279] = "move_pages",
	[280] = "utimensat",
	[281] = "epoll_pwait",
	[282] = "signalfd",
	[283] = "timerfd_create",
	[284] = "eventfd",
	[285] = "fallocate",
	[286] = "timerfd_settime",
	[287] = "timerfd_gettime",
	[288] = "accept4",
	[289] = "signalfd4",
	[290] = "eventfd2",
	[291] = "epoll_create1",
	[292] = "dup3",
	[293] = "pipe2",
	[294] = "inotify_init1",
	[295] = "preadv",
	[296] = "pwritev",
	[297] = "rt_tgsigqueueinfo",
	[298] = "perf_event_open",
	[299] = "recvmmsg",
	[300] = "fanotify_init",
	[301] = "fanotify_mark",
	[302] = "prlimit64",
	[303] = "name_to_handle_at",
	[304] = "open_by_handle_at",
	[305] = "clock_adjtime",
	[306] = "syncfs",
	[307] = "sendmmsg",
	[308] = "setns",
	[309] = "getcpu",
	[310] = "process_vm_readv",
	[311] = "process_vm_writev",
	[312] = "kcmp",
	[313] = "finit_module",
	[314] = "sched_setattr",
	[315] = "sched_getattr",
	[316] = "renameat2",
	[317] = "seccomp",
	[318] = "getrandom",
	[319] = "memfd_create",
	[320] = "kexec_file_load",
	[321] = "bpf",
	[322] = "execveat",
	[323] = "userfaultfd",
	[324] = "membarrier",
	[325] = "mlock2",
	[326] = "copy_file_range",
	[327] = "preadv2",
	[328] = "pwritev2",
	[329] = "pkey_mprotect",
	[330] = "pkey_alloc",
	[331] = "pkey_free",
	[332] = "statx",
	[333] = "io_pgetevents",
	[334] = "rseq",
	[335] = "uretprobe",
	[336] = "uprobe",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[447] = "memfd_secret",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_X86_64[] = {
	156,	/* _sysctl */
	43,	/* accept */
	288,	/* accept4 */
	21,	/* access */
	163,	/* acct */
	248,	/* add_key */
	159,	/* adjtimex */
	183,	/* afs_syscall */
	37,	/* alarm */
	158,	/* arch_prctl */
	49,	/* bind */
	321,	/* bpf */
	12,	/* brk */
	451,	/* cachestat */
	125,	/* capget */
	126,	/* capset */
	80,	/* chdir */
	90,	/* chmod */
	92,	/* chown */
	161,	/* chroot */
	305,	/* clock_adjtime */
	229,	/* clock_getres */
	228,	/* clock_gettime */
	230,	/* clock_nanosleep */
	227,	/* clock_settime */
	56,	/* clone */
	435,	/* clone3 */
	3,	/* close */
	436,	/* close_range */
	42,	/* connect */
	326,	/* copy_file_range */
	85,	/* creat */
	174,	/* create_module */
	176,	/* delete_module */
	32,	/* dup */
	33,	/* dup2 */
	292,	/* dup3 */
	213,	/* epoll_create */
	291,	/* epoll_create1 */
	233,	/* epoll_ctl */
	214,	/* epoll_ctl_old */
	281,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	232,	/* epoll_wait */
	215,	/* epoll_wait_old */
	284,	/* eventfd */
	290,	/* eventfd2 */
	59,	/* execve */
	322,	/* execveat */
	60,	/* exit */
	231,	/* exit_group */
	269,	/* faccessat */
	439,	/* faccessat2 */
	221,	/* fadvise64 */
	285,	/* fallocate */
	300,	/* fanotify_init */
	301,	/* fanotify_mark */
	81,	/* fchdir */
	91,	/* fchmod */
	268,	/* fchmodat */
	452,	/* fchmodat2 */
	93,	/* fchown */
	260,	/* fchownat */
	72,	/* fcntl */
	75,	/* fdatasync */
	193,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	313,	/* finit_module */
	196,	/* flistxattr */
	73,	/* flock */
	57,	/* fork */
	199,	/* fremovexattr */
	431,	/* fsconfig */
	190,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	5,	/* fstat */
	138,	/* fstatfs */
	74,	/* fsync */
	77,	/* ftruncate */
	202,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	261,	/* futimesat */
	177,	/* get_kernel_syms */
	239,	/* get_mempolicy */
	274,	/* get_robust_list */
	211,	/* get_thread_area */
	309,	/* getcpu */
	79,	/* getcwd */
	78,	/* getdents */
	217,	/* getdents64 */
	108,	/* getegid */
	107,	/* geteuid */
	104,	/* getgid */
	115,	/* getgroups */
	36,	/* getitimer */
	52,	/* getpeername */
	121,	/* getpgid */
	111,	/* getpgrp */
	39,	/* getpid */
	181,	/* getpmsg */
	110,	/* getppid */
	140,	/* getpriority */
	318,	/* getrandom */
	120,	/* getresgid */
	118,	/* getresuid */
	97,	/* getrlimit */
	98,	/* getrusage */
	124,	/* getsid */
	51,	/* getsockname */
	55,	/* getsockopt */
	186,	/* gettid */
	96,	/* gettimeofday */
	102,	/* getuid */
	191,	/* getxattr */
	464,	/* getxattrat */
	175,	/* init_module */
	254,	/* inotify_add_watch */
	253,	/* inotify_init */
	294,	/* inotify_init1 */
	255,	/* inotify_rm_watch */
	210,	/* io_cancel */
	207,	/* io_destroy */
	208,	/* io_getevents */
	333,	/* io_pgetevents */
	206,	/* io_setup */
	209,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	16,	/* ioctl */
	173,	/* ioperm */
	172,	/* iopl */
	252,	/* ioprio_get */
	251,	/* ioprio_set */
	312,	/* kcmp */
	320,	/* kexec_file_load */
	246,	/* kexec_load */
	250,	/* keyctl */
	62,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	94,	/* lchown */
	192,	/* lgetxattr */
	86,	/* link */
	265,	/* linkat */
	50,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	194,	/* listxattr */
	465,	/* listxattrat */
	195,	/* llistxattr */
	212,	/* lookup_dcookie */
	198,	/* lremovexattr */
	8,	/* lseek */
	189,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	6,	/* lstat */
	28,	/* madvise */
	453,	/* map_shadow_stack */
	237,	/* mbind */
	324,	/* membarrier */
	319,	/* memfd_create */
	447,	/* memfd_secret */
	256,	/* migrate_pages */
	27,	/* mincore */
	83,	/* mkdir */
	258,	/* mkdirat */
	133,	/* mknod */
	259,	/* mknodat */
	149,	/* mlock */
	325,	/* mlock2 */
	151,	/* mlockall */
	9,	/* mmap */
	154,	/* modify_ldt */
	165,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	279,	/* move_pages */
	10,	/* mprotect */
	245,	/* mq_getsetattr */
	244,	/* mq_notify */
	240,	/* mq_open */
	243,	/* mq_timedreceive */
	242,	/* mq_timedsend */
	241,	/* mq_unlink */
	25,	/* mremap */
	462,	/* mseal */
	71,	/* msgctl */
	68,	/* msgget */
	70,	/* msgrcv */
	69,	/* msgsnd */
	26,	/* msync */
	150,	/* munlock */
	152,	/* munlockall */
	11,	/* munmap */
	303,	/* name_to_handle_at */
	35,	/* nanosleep */
	262,	/* newfstatat */
	180,	/* nfsservctl */
	2,	/* open */
	304,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	257,	/* openat */
	437,	/* openat2 */
	34,	/* pause */
	298,	/* perf_event_open */
	135,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	22,	/* pipe */
	293,	/* pipe2 */
	155,	/* pivot_root */
	330,	/* pkey_alloc */
	331,	/* pkey_free */
	329,	/* pkey_mprotect */
	7,	/* poll */
	271,	/* ppoll */
	157,	/* prctl */
	17,	/* pread64 */
	295,	/* preadv */
	327,	/* preadv2 */
	302,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	310,	/* process_vm_readv */
	311,	/* process_vm_writev */
	270,	/* pselect6 */
	101,	/* ptrace */
	182,	/* putpmsg */
	18,	/* pwrite64 */
	296,	/* pwritev */
	328,	/* pwritev2 */
	178,	/* query_module */
	179,	/* quotactl */
	443,	/* quotactl_fd */
	0,	/* read */
	187,	/* readahead */
	89,	/* readlink */
	267,	/* readlinkat */
	19,	/* readv */
	169,	/* reboot */
	45,	/* recvfrom */
	299,	/* recvmmsg */
	47,	/* recvmsg */
	216,	/* remap_file_pages */
	197,	/* removexattr */
	466,	/* removexattrat */
	82,	/* rename */
	264,	/* renameat */
	316,	/* renameat2 */
	249,	/* request_key */
	219,	/* restart_syscall */
	84,	/* rmdir */
	334,	/* rseq */
	471,	/* rseq_slice_yield */
	13,	/* rt_sigaction */
	127,	/* rt_sigpending */
	14,	/* rt_sigprocmask */
	129,	/* rt_sigqueueinfo */
	15,	/* rt_sigreturn */
	130,	/* rt_sigsuspend */
	128,	/* rt_sigtimedwait */
	297,	/* rt_tgsigqueueinfo */
	146,	/* sched_get_priority_max */
	147,	/* sched_get_priority_min */
	204,	/* sched_getaffinity */
	315,	/* sched_getattr */
	143,	/* sched_getparam */
	145,	/* sched_getscheduler */
	148,	/* sched_rr_get_interval */
	203,	/* sched_setaffinity */
	314,	/* sched_setattr */
	142,	/* sched_setparam */
	144,	/* sched_setscheduler */
	24,	/* sched_yield */
	317,	/* seccomp */
	185,	/* security */
	23,	/* select */
	66,	/* semctl */
	64,	/* semget */
	65,	/* semop */
	220,	/* semtimedop */
	40,	/* sendfile */
	307,	/* sendmmsg */
	46,	/* sendmsg */
	44,	/* sendto */
	238,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	273,	/* set_robust_list */
	205,	/* set_thread_area */
	218,	/* set_tid_address */
	171,	/* setdomainname */
	123,	/* setfsgid */
	122,	/* setfsuid */
	106,	/* setgid */
	116,	/* setgroups */
	170,	/* sethostname */
	38,	/* setitimer */
	308,	/* setns */
	109,	/* setpgid */
	141,	/* setpriority */
	114,	/* setregid */
	119,	/* setresgid */
	117,	/* setresuid */
	113,	/* setreuid */
	160,	/* setrlimit */
	112,	/* setsid */
	54,	/* setsockopt */
	164,	/* settimeofday */
	105,	/* setuid */
	188,	/* setxattr */
	463,	/* setxattrat */
	30,	/* shmat */
	31,	/* shmctl */
	67,	/* shmdt */
	29,	/* shmget */
	48,	/* shutdown */
	131,	/* sigaltstack */
	282,	/* signalfd */
	289,	/* signalfd4 */
	41,	/* socket */
	53,	/* socketpair */
	275,	/* splice */
	4,	/* stat */
	137,	/* statfs */
	457,	/* statmount */
	332,	/* statx */
	168,	/* swapoff */
	167,	/* swapon */
	88,	/* symlink */
	266,	/* symlinkat */
	162,	/* sync */
	277,	/* sync_file_range */
	306,	/* syncfs */
	139,	/* sysfs */
	99,	/* sysinfo */
	103,	/* syslog */
	276,	/* tee */
	234,	/* tgkill */
	201,	/* time */
	222,	/* timer_create */
	226,	/* timer_delete */
	225,	/* timer_getoverrun */
	224,	/* timer_gettime */
	223,	/* timer_settime */
	283,	/* timerfd_create */
	287,	/* timerfd_gettime */
	286,	/* timerfd_settime */
	100,	/* times */
	200,	/* tkill */
	76,	/* truncate */
	184,	/* tuxcall */
	95,	/* umask */
	166,	/* umount2 */
	63,	/* uname */
	87,	/* unlink */
	263,	/* unlinkat */
	272,	/* unshare */
	336,	/* uprobe */
	335,	/* uretprobe */
	134,	/* uselib */
	323,	/* userfaultfd */
	136,	/* ustat */
	132,	/* utime */
	280,	/* utimensat */
	235,	/* utimes */
	58,	/* vfork */
	153,	/* vhangup */
	278,	/* vmsplice */
	236,	/* vserver */
	61,	/* wait4 */
	247,	/* waitid */
	1,	/* write */
	20,	/* writev */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__i386__) || defined(__x86_64__)

#if defined(ALL_SYSCALLTBL) || defined(__xtensa__)
static const char *const syscall_num_to_name_EM_XTENSA[] = {
	[0] = "spill",
	[1] = "xtensa",
	[2] = "available4",
	[3] = "available5",
	[4] = "available6",
	[5] = "available7",
	[6] = "available8",
	[7] = "available9",
	[8] = "open",
	[9] = "close",
	[10] = "dup",
	[11] = "dup2",
	[12] = "read",
	[13] = "write",
	[14] = "select",
	[15] = "lseek",
	[16] = "poll",
	[17] = "_llseek",
	[18] = "epoll_wait",
	[19] = "epoll_ctl",
	[20] = "epoll_create",
	[21] = "creat",
	[22] = "truncate",
	[23] = "ftruncate",
	[24] = "readv",
	[25] = "writev",
	[26] = "fsync",
	[27] = "fdatasync",
	[28] = "truncate64",
	[29] = "ftruncate64",
	[30] = "pread64",
	[31] = "pwrite64",
	[32] = "link",
	[33] = "rename",
	[34] = "symlink",
	[35] = "readlink",
	[36] = "mknod",
	[37] = "pipe",
	[38] = "unlink",
	[39] = "rmdir",
	[40] = "mkdir",
	[41] = "chdir",
	[42] = "fchdir",
	[43] = "getcwd",
	[44] = "chmod",
	[45] = "chown",
	[46] = "stat",
	[47] = "stat64",
	[48] = "lchown",
	[49] = "lstat",
	[50] = "lstat64",
	[51] = "available51",
	[52] = "fchmod",
	[53] = "fchown",
	[54] = "fstat",
	[55] = "fstat64",
	[56] = "flock",
	[57] = "access",
	[58] = "umask",
	[59] = "getdents",
	[60] = "getdents64",
	[61] = "fcntl64",
	[62] = "fallocate",
	[63] = "fadvise64_64",
	[64] = "utime",
	[65] = "utimes",
	[66] = "ioctl",
	[67] = "fcntl",
	[68] = "setxattr",
	[69] = "getxattr",
	[70] = "listxattr",
	[71] = "removexattr",
	[72] = "lsetxattr",
	[73] = "lgetxattr",
	[74] = "llistxattr",
	[75] = "lremovexattr",
	[76] = "fsetxattr",
	[77] = "fgetxattr",
	[78] = "flistxattr",
	[79] = "fremovexattr",
	[80] = "mmap2",
	[81] = "munmap",
	[82] = "mprotect",
	[83] = "brk",
	[84] = "mlock",
	[85] = "munlock",
	[86] = "mlockall",
	[87] = "munlockall",
	[88] = "mremap",
	[89] = "msync",
	[90] = "mincore",
	[91] = "madvise",
	[92] = "shmget",
	[93] = "shmat",
	[94] = "shmctl",
	[95] = "shmdt",
	[96] = "socket",
	[97] = "setsockopt",
	[98] = "getsockopt",
	[99] = "shutdown",
	[100] = "bind",
	[101] = "connect",
	[102] = "listen",
	[103] = "accept",
	[104] = "getsockname",
	[105] = "getpeername",
	[106] = "sendmsg",
	[107] = "recvmsg",
	[108] = "send",
	[109] = "recv",
	[110] = "sendto",
	[111] = "recvfrom",
	[112] = "socketpair",
	[113] = "sendfile",
	[114] = "sendfile64",
	[115] = "sendmmsg",
	[116] = "clone",
	[117] = "execve",
	[118] = "exit",
	[119] = "exit_group",
	[120] = "getpid",
	[121] = "wait4",
	[122] = "waitid",
	[123] = "kill",
	[124] = "tkill",
	[125] = "tgkill",
	[126] = "set_tid_address",
	[127] = "gettid",
	[128] = "setsid",
	[129] = "getsid",
	[130] = "prctl",
	[131] = "personality",
	[132] = "getpriority",
	[133] = "setpriority",
	[134] = "setitimer",
	[135] = "getitimer",
	[136] = "setuid",
	[137] = "getuid",
	[138] = "setgid",
	[139] = "getgid",
	[140] = "geteuid",
	[141] = "getegid",
	[142] = "setreuid",
	[143] = "setregid",
	[144] = "setresuid",
	[145] = "getresuid",
	[146] = "setresgid",
	[147] = "getresgid",
	[148] = "setpgid",
	[149] = "getpgid",
	[150] = "getppid",
	[151] = "getpgrp",
	[152] = "reserved152",
	[153] = "reserved153",
	[154] = "times",
	[155] = "acct",
	[156] = "sched_setaffinity",
	[157] = "sched_getaffinity",
	[158] = "capget",
	[159] = "capset",
	[160] = "ptrace",
	[161] = "semtimedop",
	[162] = "semget",
	[163] = "semop",
	[164] = "semctl",
	[165] = "available165",
	[166] = "msgget",
	[167] = "msgsnd",
	[168] = "msgrcv",
	[169] = "msgctl",
	[170] = "available170",
	[171] = "umount2",
	[172] = "mount",
	[173] = "swapon",
	[174] = "chroot",
	[175] = "pivot_root",
	[176] = "umount",
	[177] = "swapoff",
	[178] = "sync",
	[179] = "syncfs",
	[180] = "setfsuid",
	[181] = "setfsgid",
	[182] = "sysfs",
	[183] = "ustat",
	[184] = "statfs",
	[185] = "fstatfs",
	[186] = "statfs64",
	[187] = "fstatfs64",
	[188] = "setrlimit",
	[189] = "getrlimit",
	[190] = "getrusage",
	[191] = "futex",
	[192] = "gettimeofday",
	[193] = "settimeofday",
	[194] = "adjtimex",
	[195] = "nanosleep",
	[196] = "getgroups",
	[197] = "setgroups",
	[198] = "sethostname",
	[199] = "setdomainname",
	[200] = "syslog",
	[201] = "vhangup",
	[202] = "uselib",
	[203] = "reboot",
	[204] = "quotactl",
	[205] = "nfsservctl",
	[206] = "_sysctl",
	[207] = "bdflush",
	[208] = "uname",
	[209] = "sysinfo",
	[210] = "init_module",
	[211] = "delete_module",
	[212] = "sched_setparam",
	[213] = "sched_getparam",
	[214] = "sched_setscheduler",
	[215] = "sched_getscheduler",
	[216] = "sched_get_priority_max",
	[217] = "sched_get_priority_min",
	[218] = "sched_rr_get_interval",
	[219] = "sched_yield",
	[222] = "available222",
	[223] = "restart_syscall",
	[224] = "sigaltstack",
	[225] = "rt_sigreturn",
	[226] = "rt_sigaction",
	[227] = "rt_sigprocmask",
	[228] = "rt_sigpending",
	[229] = "rt_sigtimedwait",
	[230] = "rt_sigqueueinfo",
	[231] = "rt_sigsuspend",
	[232] = "mq_open",
	[233] = "mq_unlink",
	[234] = "mq_timedsend",
	[235] = "mq_timedreceive",
	[236] = "mq_notify",
	[237] = "mq_getsetattr",
	[238] = "available238",
	[239] = "io_setup",
	[240] = "io_destroy",
	[241] = "io_submit",
	[242] = "io_getevents",
	[243] = "io_cancel",
	[244] = "clock_settime",
	[245] = "clock_gettime",
	[246] = "clock_getres",
	[247] = "clock_nanosleep",
	[248] = "timer_create",
	[249] = "timer_delete",
	[250] = "timer_settime",
	[251] = "timer_gettime",
	[252] = "timer_getoverrun",
	[253] = "reserved253",
	[254] = "lookup_dcookie",
	[255] = "available255",
	[256] = "add_key",
	[257] = "request_key",
	[258] = "keyctl",
	[259] = "available259",
	[260] = "readahead",
	[261] = "remap_file_pages",
	[262] = "migrate_pages",
	[263] = "mbind",
	[264] = "get_mempolicy",
	[265] = "set_mempolicy",
	[266] = "unshare",
	[267] = "move_pages",
	[268] = "splice",
	[269] = "tee",
	[270] = "vmsplice",
	[271] = "available271",
	[272] = "pselect6",
	[273] = "ppoll",
	[274] = "epoll_pwait",
	[275] = "epoll_create1",
	[276] = "inotify_init",
	[277] = "inotify_add_watch",
	[278] = "inotify_rm_watch",
	[279] = "inotify_init1",
	[280] = "getcpu",
	[281] = "kexec_load",
	[282] = "ioprio_set",
	[283] = "ioprio_get",
	[284] = "set_robust_list",
	[285] = "get_robust_list",
	[286] = "available286",
	[287] = "available287",
	[288] = "openat",
	[289] = "mkdirat",
	[290] = "mknodat",
	[291] = "unlinkat",
	[292] = "renameat",
	[293] = "linkat",
	[294] = "symlinkat",
	[295] = "readlinkat",
	[296] = "utimensat",
	[297] = "fchownat",
	[298] = "futimesat",
	[299] = "fstatat64",
	[300] = "fchmodat",
	[301] = "faccessat",
	[302] = "available302",
	[303] = "available303",
	[304] = "signalfd",
	[306] = "eventfd",
	[307] = "recvmmsg",
	[308] = "setns",
	[309] = "signalfd4",
	[310] = "dup3",
	[311] = "pipe2",
	[312] = "timerfd_create",
	[313] = "timerfd_settime",
	[314] = "timerfd_gettime",
	[315] = "available315",
	[316] = "eventfd2",
	[317] = "preadv",
	[318] = "pwritev",
	[319] = "available319",
	[320] = "fanotify_init",
	[321] = "fanotify_mark",
	[322] = "process_vm_readv",
	[323] = "process_vm_writev",
	[324] = "name_to_handle_at",
	[325] = "open_by_handle_at",
	[326] = "sync_file_range2",
	[327] = "perf_event_open",
	[328] = "rt_tgsigqueueinfo",
	[329] = "clock_adjtime",
	[330] = "prlimit64",
	[331] = "kcmp",
	[332] = "finit_module",
	[333] = "accept4",
	[334] = "sched_setattr",
	[335] = "sched_getattr",
	[336] = "renameat2",
	[337] = "seccomp",
	[338] = "getrandom",
	[339] = "memfd_create",
	[340] = "bpf",
	[341] = "execveat",
	[342] = "userfaultfd",
	[343] = "membarrier",
	[344] = "mlock2",
	[345] = "copy_file_range",
	[346] = "preadv2",
	[347] = "pwritev2",
	[348] = "pkey_mprotect",
	[349] = "pkey_alloc",
	[350] = "pkey_free",
	[351] = "statx",
	[352] = "rseq",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_XTENSA[] = {
	17,	/* _llseek */
	206,	/* _sysctl */
	103,	/* accept */
	333,	/* accept4 */
	57,	/* access */
	155,	/* acct */
	256,	/* add_key */
	194,	/* adjtimex */
	165,	/* available165 */
	170,	/* available17 */
	222,	/* available222 */
	238,	/* available238 */
	255,	/* available255 */
	259,	/* available259 */
	271,	/* available271 */
	286,	/* available286 */
	287,	/* available287 */
	302,	/* available302 */
	303,	/* available303 */
	315,	/* available315 */
	319,	/* available319 */
	2,	/* available4 */
	3,	/* available5 */
	51,	/* available51 */
	4,	/* available6 */
	5,	/* available7 */
	6,	/* available8 */
	7,	/* available9 */
	207,	/* bdflush */
	100,	/* bind */
	340,	/* bpf */
	83,	/* brk */
	451,	/* cachestat */
	158,	/* capget */
	159,	/* capset */
	41,	/* chdir */
	44,	/* chmod */
	45,	/* chown */
	174,	/* chroot */
	329,	/* clock_adjtime */
	405,	/* clock_adjtime64 */
	246,	/* clock_getres */
	406,	/* clock_getres_time64 */
	245,	/* clock_gettime */
	403,	/* clock_gettime64 */
	247,	/* clock_nanosleep */
	407,	/* clock_nanosleep_time64 */
	244,	/* clock_settime */
	404,	/* clock_settime64 */
	116,	/* clone */
	435,	/* clone3 */
	9,	/* close */
	436,	/* close_range */
	101,	/* connect */
	345,	/* copy_file_range */
	21,	/* creat */
	211,	/* delete_module */
	10,	/* dup */
	11,	/* dup2 */
	310,	/* dup3 */
	20,	/* epoll_create */
	275,	/* epoll_create1 */
	19,	/* epoll_ctl */
	274,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	18,	/* epoll_wait */
	306,	/* eventfd */
	316,	/* eventfd2 */
	117,	/* execve */
	341,	/* execveat */
	118,	/* exit */
	119,	/* exit_group */
	301,	/* faccessat */
	439,	/* faccessat2 */
	63,	/* fadvise64_64 */
	62,	/* fallocate */
	320,	/* fanotify_init */
	321,	/* fanotify_mark */
	42,	/* fchdir */
	52,	/* fchmod */
	300,	/* fchmodat */
	452,	/* fchmodat2 */
	53,	/* fchown */
	297,	/* fchownat */
	67,	/* fcntl */
	61,	/* fcntl64 */
	27,	/* fdatasync */
	77,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	332,	/* finit_module */
	78,	/* flistxattr */
	56,	/* flock */
	79,	/* fremovexattr */
	431,	/* fsconfig */
	76,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	54,	/* fstat */
	55,	/* fstat64 */
	299,	/* fstatat64 */
	185,	/* fstatfs */
	187,	/* fstatfs64 */
	26,	/* fsync */
	23,	/* ftruncate */
	29,	/* ftruncate64 */
	191,	/* futex */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	298,	/* futimesat */
	264,	/* get_mempolicy */
	285,	/* get_robust_list */
	280,	/* getcpu */
	43,	/* getcwd */
	59,	/* getdents */
	60,	/* getdents64 */
	141,	/* getegid */
	140,	/* geteuid */
	139,	/* getgid */
	196,	/* getgroups */
	135,	/* getitimer */
	105,	/* getpeername */
	149,	/* getpgid */
	151,	/* getpgrp */
	120,	/* getpid */
	150,	/* getppid */
	132,	/* getpriority */
	338,	/* getrandom */
	147,	/* getresgid */
	145,	/* getresuid */
	189,	/* getrlimit */
	190,	/* getrusage */
	129,	/* getsid */
	104,	/* getsockname */
	98,	/* getsockopt */
	127,	/* gettid */
	192,	/* gettimeofday */
	137,	/* getuid */
	69,	/* getxattr */
	464,	/* getxattrat */
	210,	/* init_module */
	277,	/* inotify_add_watch */
	276,	/* inotify_init */
	279,	/* inotify_init1 */
	278,	/* inotify_rm_watch */
	243,	/* io_cancel */
	240,	/* io_destroy */
	242,	/* io_getevents */
	416,	/* io_pgetevents_time64 */
	239,	/* io_setup */
	241,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	66,	/* ioctl */
	283,	/* ioprio_get */
	282,	/* ioprio_set */
	331,	/* kcmp */
	281,	/* kexec_load */
	258,	/* keyctl */
	123,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	48,	/* lchown */
	73,	/* lgetxattr */
	32,	/* link */
	293,	/* linkat */
	102,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	70,	/* listxattr */
	465,	/* listxattrat */
	74,	/* llistxattr */
	254,	/* lookup_dcookie */
	75,	/* lremovexattr */
	15,	/* lseek */
	72,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	49,	/* lstat */
	50,	/* lstat64 */
	91,	/* madvise */
	453,	/* map_shadow_stack */
	263,	/* mbind */
	343,	/* membarrier */
	339,	/* memfd_create */
	262,	/* migrate_pages */
	90,	/* mincore */
	40,	/* mkdir */
	289,	/* mkdirat */
	36,	/* mknod */
	290,	/* mknodat */
	84,	/* mlock */
	344,	/* mlock2 */
	86,	/* mlockall */
	80,	/* mmap2 */
	172,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	267,	/* move_pages */
	82,	/* mprotect */
	237,	/* mq_getsetattr */
	236,	/* mq_notify */
	232,	/* mq_open */
	235,	/* mq_timedreceive */
	419,	/* mq_timedreceive_time64 */
	234,	/* mq_timedsend */
	418,	/* mq_timedsend_time64 */
	233,	/* mq_unlink */
	88,	/* mremap */
	462,	/* mseal */
	169,	/* msgctl */
	166,	/* msgget */
	168,	/* msgrcv */
	167,	/* msgsnd */
	89,	/* msync */
	85,	/* munlock */
	87,	/* munlockall */
	81,	/* munmap */
	324,	/* name_to_handle_at */
	195,	/* nanosleep */
	205,	/* nfsservctl */
	8,	/* open */
	325,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	288,	/* openat */
	437,	/* openat2 */
	327,	/* perf_event_open */
	131,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	37,	/* pipe */
	311,	/* pipe2 */
	175,	/* pivot_root */
	349,	/* pkey_alloc */
	350,	/* pkey_free */
	348,	/* pkey_mprotect */
	16,	/* poll */
	273,	/* ppoll */
	414,	/* ppoll_time64 */
	130,	/* prctl */
	30,	/* pread64 */
	317,	/* preadv */
	346,	/* preadv2 */
	330,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	322,	/* process_vm_readv */
	323,	/* process_vm_writev */
	272,	/* pselect6 */
	413,	/* pselect6_time64 */
	160,	/* ptrace */
	31,	/* pwrite64 */
	318,	/* pwritev */
	347,	/* pwritev2 */
	204,	/* quotactl */
	443,	/* quotactl_fd */
	12,	/* read */
	260,	/* readahead */
	35,	/* readlink */
	295,	/* readlinkat */
	24,	/* readv */
	203,	/* reboot */
	109,	/* recv */
	111,	/* recvfrom */
	307,	/* recvmmsg */
	417,	/* recvmmsg_time64 */
	107,	/* recvmsg */
	261,	/* remap_file_pages */
	71,	/* removexattr */
	466,	/* removexattrat */
	33,	/* rename */
	292,	/* renameat */
	336,	/* renameat2 */
	257,	/* request_key */
	152,	/* reserved152 */
	153,	/* reserved153 */
	253,	/* reserved253 */
	223,	/* restart_syscall */
	39,	/* rmdir */
	352,	/* rseq */
	471,	/* rseq_slice_yield */
	226,	/* rt_sigaction */
	228,	/* rt_sigpending */
	227,	/* rt_sigprocmask */
	230,	/* rt_sigqueueinfo */
	225,	/* rt_sigreturn */
	231,	/* rt_sigsuspend */
	229,	/* rt_sigtimedwait */
	421,	/* rt_sigtimedwait_time64 */
	328,	/* rt_tgsigqueueinfo */
	216,	/* sched_get_priority_max */
	217,	/* sched_get_priority_min */
	157,	/* sched_getaffinity */
	335,	/* sched_getattr */
	213,	/* sched_getparam */
	215,	/* sched_getscheduler */
	218,	/* sched_rr_get_interval */
	423,	/* sched_rr_get_interval_time64 */
	156,	/* sched_setaffinity */
	334,	/* sched_setattr */
	212,	/* sched_setparam */
	214,	/* sched_setscheduler */
	219,	/* sched_yield */
	337,	/* seccomp */
	14,	/* select */
	164,	/* semctl */
	162,	/* semget */
	163,	/* semop */
	161,	/* semtimedop */
	420,	/* semtimedop_time64 */
	108,	/* send */
	113,	/* sendfile */
	114,	/* sendfile64 */
	115,	/* sendmmsg */
	106,	/* sendmsg */
	110,	/* sendto */
	265,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	284,	/* set_robust_list */
	126,	/* set_tid_address */
	199,	/* setdomainname */
	181,	/* setfsgid */
	180,	/* setfsuid */
	138,	/* setgid */
	197,	/* setgroups */
	198,	/* sethostname */
	134,	/* setitimer */
	308,	/* setns */
	148,	/* setpgid */
	133,	/* setpriority */
	143,	/* setregid */
	146,	/* setresgid */
	144,	/* setresuid */
	142,	/* setreuid */
	188,	/* setrlimit */
	128,	/* setsid */
	97,	/* setsockopt */
	193,	/* settimeofday */
	136,	/* setuid */
	68,	/* setxattr */
	463,	/* setxattrat */
	93,	/* shmat */
	94,	/* shmctl */
	95,	/* shmdt */
	92,	/* shmget */
	99,	/* shutdown */
	224,	/* sigaltstack */
	304,	/* signalfd */
	309,	/* signalfd4 */
	96,	/* socket */
	112,	/* socketpair */
	0,	/* spill */
	268,	/* splice */
	46,	/* stat */
	47,	/* stat64 */
	184,	/* statfs */
	186,	/* statfs64 */
	457,	/* statmount */
	351,	/* statx */
	177,	/* swapoff */
	173,	/* swapon */
	34,	/* symlink */
	294,	/* symlinkat */
	178,	/* sync */
	326,	/* sync_file_range2 */
	179,	/* syncfs */
	182,	/* sysfs */
	209,	/* sysinfo */
	200,	/* syslog */
	269,	/* tee */
	125,	/* tgkill */
	248,	/* timer_create */
	249,	/* timer_delete */
	252,	/* timer_getoverrun */
	251,	/* timer_gettime */
	408,	/* timer_gettime64 */
	250,	/* timer_settime */
	409,	/* timer_settime64 */
	312,	/* timerfd_create */
	314,	/* timerfd_gettime */
	410,	/* timerfd_gettime64 */
	313,	/* timerfd_settime */
	411,	/* timerfd_settime64 */
	154,	/* times */
	124,	/* tkill */
	22,	/* truncate */
	28,	/* truncate64 */
	58,	/* umask */
	176,	/* umount */
	171,	/* umount2 */
	208,	/* uname */
	38,	/* unlink */
	291,	/* unlinkat */
	266,	/* unshare */
	202,	/* uselib */
	342,	/* userfaultfd */
	183,	/* ustat */
	64,	/* utime */
	296,	/* utimensat */
	412,	/* utimensat_time64 */
	65,	/* utimes */
	201,	/* vhangup */
	270,	/* vmsplice */
	121,	/* wait4 */
	122,	/* waitid */
	13,	/* write */
	25,	/* writev */
	1,	/* xtensa */
};
#endif // defined(ALL_SYSCALLTBL) || defined(__xtensa__)

#if __BITS_PER_LONG != 64
static const char *const syscall_num_to_name_EM_NONE[] = {
	[0] = "io_setup",
	[1] = "io_destroy",
	[2] = "io_submit",
	[3] = "io_cancel",
	[5] = "setxattr",
	[6] = "lsetxattr",
	[7] = "fsetxattr",
	[8] = "getxattr",
	[9] = "lgetxattr",
	[10] = "fgetxattr",
	[11] = "listxattr",
	[12] = "llistxattr",
	[13] = "flistxattr",
	[14] = "removexattr",
	[15] = "lremovexattr",
	[16] = "fremovexattr",
	[17] = "getcwd",
	[18] = "lookup_dcookie",
	[19] = "eventfd2",
	[20] = "epoll_create1",
	[21] = "epoll_ctl",
	[22] = "epoll_pwait",
	[23] = "dup",
	[24] = "dup3",
	[25] = "fcntl64",
	[26] = "inotify_init1",
	[27] = "inotify_add_watch",
	[28] = "inotify_rm_watch",
	[29] = "ioctl",
	[30] = "ioprio_set",
	[31] = "ioprio_get",
	[32] = "flock",
	[33] = "mknodat",
	[34] = "mkdirat",
	[35] = "unlinkat",
	[36] = "symlinkat",
	[37] = "linkat",
	[39] = "umount2",
	[40] = "mount",
	[41] = "pivot_root",
	[42] = "nfsservctl",
	[43] = "statfs64",
	[44] = "fstatfs64",
	[45] = "truncate64",
	[46] = "ftruncate64",
	[47] = "fallocate",
	[48] = "faccessat",
	[49] = "chdir",
	[50] = "fchdir",
	[51] = "chroot",
	[52] = "fchmod",
	[53] = "fchmodat",
	[54] = "fchownat",
	[55] = "fchown",
	[56] = "openat",
	[57] = "close",
	[58] = "vhangup",
	[59] = "pipe2",
	[60] = "quotactl",
	[61] = "getdents64",
	[62] = "llseek",
	[63] = "read",
	[64] = "write",
	[65] = "readv",
	[66] = "writev",
	[67] = "pread64",
	[68] = "pwrite64",
	[69] = "preadv",
	[70] = "pwritev",
	[71] = "sendfile64",
	[74] = "signalfd4",
	[75] = "vmsplice",
	[76] = "splice",
	[77] = "tee",
	[78] = "readlinkat",
	[81] = "sync",
	[82] = "fsync",
	[83] = "fdatasync",
	[84] = "sync_file_range",
	[85] = "timerfd_create",
	[89] = "acct",
	[90] = "capget",
	[91] = "capset",
	[92] = "personality",
	[93] = "exit",
	[94] = "exit_group",
	[95] = "waitid",
	[96] = "set_tid_address",
	[97] = "unshare",
	[99] = "set_robust_list",
	[100] = "get_robust_list",
	[102] = "getitimer",
	[103] = "setitimer",
	[104] = "kexec_load",
	[105] = "init_module",
	[106] = "delete_module",
	[107] = "timer_create",
	[109] = "timer_getoverrun",
	[111] = "timer_delete",
	[116] = "syslog",
	[117] = "ptrace",
	[118] = "sched_setparam",
	[119] = "sched_setscheduler",
	[120] = "sched_getscheduler",
	[121] = "sched_getparam",
	[122] = "sched_setaffinity",
	[123] = "sched_getaffinity",
	[124] = "sched_yield",
	[125] = "sched_get_priority_max",
	[126] = "sched_get_priority_min",
	[128] = "restart_syscall",
	[129] = "kill",
	[130] = "tkill",
	[131] = "tgkill",
	[132] = "sigaltstack",
	[133] = "rt_sigsuspend",
	[134] = "rt_sigaction",
	[135] = "rt_sigprocmask",
	[136] = "rt_sigpending",
	[138] = "rt_sigqueueinfo",
	[139] = "rt_sigreturn",
	[140] = "setpriority",
	[141] = "getpriority",
	[142] = "reboot",
	[143] = "setregid",
	[144] = "setgid",
	[145] = "setreuid",
	[146] = "setuid",
	[147] = "setresuid",
	[148] = "getresuid",
	[149] = "setresgid",
	[150] = "getresgid",
	[151] = "setfsuid",
	[152] = "setfsgid",
	[153] = "times",
	[154] = "setpgid",
	[155] = "getpgid",
	[156] = "getsid",
	[157] = "setsid",
	[158] = "getgroups",
	[159] = "setgroups",
	[160] = "uname",
	[161] = "sethostname",
	[162] = "setdomainname",
	[165] = "getrusage",
	[166] = "umask",
	[167] = "prctl",
	[168] = "getcpu",
	[172] = "getpid",
	[173] = "getppid",
	[174] = "getuid",
	[175] = "geteuid",
	[176] = "getgid",
	[177] = "getegid",
	[178] = "gettid",
	[179] = "sysinfo",
	[180] = "mq_open",
	[181] = "mq_unlink",
	[184] = "mq_notify",
	[185] = "mq_getsetattr",
	[186] = "msgget",
	[187] = "msgctl",
	[188] = "msgrcv",
	[189] = "msgsnd",
	[190] = "semget",
	[191] = "semctl",
	[193] = "semop",
	[194] = "shmget",
	[195] = "shmctl",
	[196] = "shmat",
	[197] = "shmdt",
	[198] = "socket",
	[199] = "socketpair",
	[200] = "bind",
	[201] = "listen",
	[202] = "accept",
	[203] = "connect",
	[204] = "getsockname",
	[205] = "getpeername",
	[206] = "sendto",
	[207] = "recvfrom",
	[208] = "setsockopt",
	[209] = "getsockopt",
	[210] = "shutdown",
	[211] = "sendmsg",
	[212] = "recvmsg",
	[213] = "readahead",
	[214] = "brk",
	[215] = "munmap",
	[216] = "mremap",
	[217] = "add_key",
	[218] = "request_key",
	[219] = "keyctl",
	[220] = "clone",
	[221] = "execve",
	[222] = "mmap2",
	[223] = "fadvise64_64",
	[224] = "swapon",
	[225] = "swapoff",
	[226] = "mprotect",
	[227] = "msync",
	[228] = "mlock",
	[229] = "munlock",
	[230] = "mlockall",
	[231] = "munlockall",
	[232] = "mincore",
	[233] = "madvise",
	[234] = "remap_file_pages",
	[235] = "mbind",
	[236] = "get_mempolicy",
	[237] = "set_mempolicy",
	[238] = "migrate_pages",
	[239] = "move_pages",
	[240] = "rt_tgsigqueueinfo",
	[241] = "perf_event_open",
	[242] = "accept4",
	[261] = "prlimit64",
	[262] = "fanotify_init",
	[263] = "fanotify_mark",
	[264] = "name_to_handle_at",
	[265] = "open_by_handle_at",
	[267] = "syncfs",
	[268] = "setns",
	[269] = "sendmmsg",
	[270] = "process_vm_readv",
	[271] = "process_vm_writev",
	[272] = "kcmp",
	[273] = "finit_module",
	[274] = "sched_setattr",
	[275] = "sched_getattr",
	[276] = "renameat2",
	[277] = "seccomp",
	[278] = "getrandom",
	[279] = "memfd_create",
	[280] = "bpf",
	[281] = "execveat",
	[282] = "userfaultfd",
	[283] = "membarrier",
	[284] = "mlock2",
	[285] = "copy_file_range",
	[286] = "preadv2",
	[287] = "pwritev2",
	[288] = "pkey_mprotect",
	[289] = "pkey_alloc",
	[290] = "pkey_free",
	[291] = "statx",
	[293] = "rseq",
	[294] = "kexec_file_load",
	[403] = "clock_gettime64",
	[404] = "clock_settime64",
	[405] = "clock_adjtime64",
	[406] = "clock_getres_time64",
	[407] = "clock_nanosleep_time64",
	[408] = "timer_gettime64",
	[409] = "timer_settime64",
	[410] = "timerfd_gettime64",
	[411] = "timerfd_settime64",
	[412] = "utimensat_time64",
	[413] = "pselect6_time64",
	[414] = "ppoll_time64",
	[416] = "io_pgetevents_time64",
	[417] = "recvmmsg_time64",
	[418] = "mq_timedsend_time64",
	[419] = "mq_timedreceive_time64",
	[420] = "semtimedop_time64",
	[421] = "rt_sigtimedwait_time64",
	[422] = "futex_time64",
	[423] = "sched_rr_get_interval_time64",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_NONE[] = {
	202,	/* accept */
	242,	/* accept4 */
	89,	/* acct */
	217,	/* add_key */
	200,	/* bind */
	280,	/* bpf */
	214,	/* brk */
	451,	/* cachestat */
	90,	/* capget */
	91,	/* capset */
	49,	/* chdir */
	51,	/* chroot */
	405,	/* clock_adjtime64 */
	406,	/* clock_getres_time64 */
	403,	/* clock_gettime64 */
	407,	/* clock_nanosleep_time64 */
	404,	/* clock_settime64 */
	220,	/* clone */
	435,	/* clone3 */
	57,	/* close */
	436,	/* close_range */
	203,	/* connect */
	285,	/* copy_file_range */
	106,	/* delete_module */
	23,	/* dup */
	24,	/* dup3 */
	20,	/* epoll_create1 */
	21,	/* epoll_ctl */
	22,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	19,	/* eventfd2 */
	221,	/* execve */
	281,	/* execveat */
	93,	/* exit */
	94,	/* exit_group */
	48,	/* faccessat */
	439,	/* faccessat2 */
	223,	/* fadvise64_64 */
	47,	/* fallocate */
	262,	/* fanotify_init */
	263,	/* fanotify_mark */
	50,	/* fchdir */
	52,	/* fchmod */
	53,	/* fchmodat */
	452,	/* fchmodat2 */
	55,	/* fchown */
	54,	/* fchownat */
	25,	/* fcntl64 */
	83,	/* fdatasync */
	10,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	273,	/* finit_module */
	13,	/* flistxattr */
	32,	/* flock */
	16,	/* fremovexattr */
	431,	/* fsconfig */
	7,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	44,	/* fstatfs64 */
	82,	/* fsync */
	46,	/* ftruncate64 */
	456,	/* futex_requeue */
	422,	/* futex_time64 */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	236,	/* get_mempolicy */
	100,	/* get_robust_list */
	168,	/* getcpu */
	17,	/* getcwd */
	61,	/* getdents64 */
	177,	/* getegid */
	175,	/* geteuid */
	176,	/* getgid */
	158,	/* getgroups */
	102,	/* getitimer */
	205,	/* getpeername */
	155,	/* getpgid */
	172,	/* getpid */
	173,	/* getppid */
	141,	/* getpriority */
	278,	/* getrandom */
	150,	/* getresgid */
	148,	/* getresuid */
	165,	/* getrusage */
	156,	/* getsid */
	204,	/* getsockname */
	209,	/* getsockopt */
	178,	/* gettid */
	174,	/* getuid */
	8,	/* getxattr */
	464,	/* getxattrat */
	105,	/* init_module */
	27,	/* inotify_add_watch */
	26,	/* inotify_init1 */
	28,	/* inotify_rm_watch */
	3,	/* io_cancel */
	1,	/* io_destroy */
	416,	/* io_pgetevents_time64 */
	0,	/* io_setup */
	2,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	29,	/* ioctl */
	31,	/* ioprio_get */
	30,	/* ioprio_set */
	272,	/* kcmp */
	294,	/* kexec_file_load */
	104,	/* kexec_load */
	219,	/* keyctl */
	129,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	9,	/* lgetxattr */
	37,	/* linkat */
	201,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	11,	/* listxattr */
	465,	/* listxattrat */
	12,	/* llistxattr */
	62,	/* llseek */
	18,	/* lookup_dcookie */
	15,	/* lremovexattr */
	6,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	233,	/* madvise */
	453,	/* map_shadow_stack */
	235,	/* mbind */
	283,	/* membarrier */
	279,	/* memfd_create */
	238,	/* migrate_pages */
	232,	/* mincore */
	34,	/* mkdirat */
	33,	/* mknodat */
	228,	/* mlock */
	284,	/* mlock2 */
	230,	/* mlockall */
	222,	/* mmap2 */
	40,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	239,	/* move_pages */
	226,	/* mprotect */
	185,	/* mq_getsetattr */
	184,	/* mq_notify */
	180,	/* mq_open */
	419,	/* mq_timedreceive_time64 */
	418,	/* mq_timedsend_time64 */
	181,	/* mq_unlink */
	216,	/* mremap */
	462,	/* mseal */
	187,	/* msgctl */
	186,	/* msgget */
	188,	/* msgrcv */
	189,	/* msgsnd */
	227,	/* msync */
	229,	/* munlock */
	231,	/* munlockall */
	215,	/* munmap */
	264,	/* name_to_handle_at */
	42,	/* nfsservctl */
	265,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	56,	/* openat */
	437,	/* openat2 */
	241,	/* perf_event_open */
	92,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	59,	/* pipe2 */
	41,	/* pivot_root */
	289,	/* pkey_alloc */
	290,	/* pkey_free */
	288,	/* pkey_mprotect */
	414,	/* ppoll_time64 */
	167,	/* prctl */
	67,	/* pread64 */
	69,	/* preadv */
	286,	/* preadv2 */
	261,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	270,	/* process_vm_readv */
	271,	/* process_vm_writev */
	413,	/* pselect6_time64 */
	117,	/* ptrace */
	68,	/* pwrite64 */
	70,	/* pwritev */
	287,	/* pwritev2 */
	60,	/* quotactl */
	443,	/* quotactl_fd */
	63,	/* read */
	213,	/* readahead */
	78,	/* readlinkat */
	65,	/* readv */
	142,	/* reboot */
	207,	/* recvfrom */
	417,	/* recvmmsg_time64 */
	212,	/* recvmsg */
	234,	/* remap_file_pages */
	14,	/* removexattr */
	466,	/* removexattrat */
	276,	/* renameat2 */
	218,	/* request_key */
	128,	/* restart_syscall */
	293,	/* rseq */
	471,	/* rseq_slice_yield */
	134,	/* rt_sigaction */
	136,	/* rt_sigpending */
	135,	/* rt_sigprocmask */
	138,	/* rt_sigqueueinfo */
	139,	/* rt_sigreturn */
	133,	/* rt_sigsuspend */
	421,	/* rt_sigtimedwait_time64 */
	240,	/* rt_tgsigqueueinfo */
	125,	/* sched_get_priority_max */
	126,	/* sched_get_priority_min */
	123,	/* sched_getaffinity */
	275,	/* sched_getattr */
	121,	/* sched_getparam */
	120,	/* sched_getscheduler */
	423,	/* sched_rr_get_interval_time64 */
	122,	/* sched_setaffinity */
	274,	/* sched_setattr */
	118,	/* sched_setparam */
	119,	/* sched_setscheduler */
	124,	/* sched_yield */
	277,	/* seccomp */
	191,	/* semctl */
	190,	/* semget */
	193,	/* semop */
	420,	/* semtimedop_time64 */
	71,	/* sendfile64 */
	269,	/* sendmmsg */
	211,	/* sendmsg */
	206,	/* sendto */
	237,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	99,	/* set_robust_list */
	96,	/* set_tid_address */
	162,	/* setdomainname */
	152,	/* setfsgid */
	151,	/* setfsuid */
	144,	/* setgid */
	159,	/* setgroups */
	161,	/* sethostname */
	103,	/* setitimer */
	268,	/* setns */
	154,	/* setpgid */
	140,	/* setpriority */
	143,	/* setregid */
	149,	/* setresgid */
	147,	/* setresuid */
	145,	/* setreuid */
	157,	/* setsid */
	208,	/* setsockopt */
	146,	/* setuid */
	5,	/* setxattr */
	463,	/* setxattrat */
	196,	/* shmat */
	195,	/* shmctl */
	197,	/* shmdt */
	194,	/* shmget */
	210,	/* shutdown */
	132,	/* sigaltstack */
	74,	/* signalfd4 */
	198,	/* socket */
	199,	/* socketpair */
	76,	/* splice */
	43,	/* statfs64 */
	457,	/* statmount */
	291,	/* statx */
	225,	/* swapoff */
	224,	/* swapon */
	36,	/* symlinkat */
	81,	/* sync */
	84,	/* sync_file_range */
	267,	/* syncfs */
	179,	/* sysinfo */
	116,	/* syslog */
	77,	/* tee */
	131,	/* tgkill */
	107,	/* timer_create */
	111,	/* timer_delete */
	109,	/* timer_getoverrun */
	408,	/* timer_gettime64 */
	409,	/* timer_settime64 */
	85,	/* timerfd_create */
	410,	/* timerfd_gettime64 */
	411,	/* timerfd_settime64 */
	153,	/* times */
	130,	/* tkill */
	45,	/* truncate64 */
	166,	/* umask */
	39,	/* umount2 */
	160,	/* uname */
	35,	/* unlinkat */
	97,	/* unshare */
	282,	/* userfaultfd */
	412,	/* utimensat_time64 */
	58,	/* vhangup */
	75,	/* vmsplice */
	95,	/* waitid */
	64,	/* write */
	66,	/* writev */
};
#else
static const char *const syscall_num_to_name_EM_NONE[] = {
	[0] = "io_setup",
	[1] = "io_destroy",
	[2] = "io_submit",
	[3] = "io_cancel",
	[4] = "io_getevents",
	[5] = "setxattr",
	[6] = "lsetxattr",
	[7] = "fsetxattr",
	[8] = "getxattr",
	[9] = "lgetxattr",
	[10] = "fgetxattr",
	[11] = "listxattr",
	[12] = "llistxattr",
	[13] = "flistxattr",
	[14] = "removexattr",
	[15] = "lremovexattr",
	[16] = "fremovexattr",
	[17] = "getcwd",
	[18] = "lookup_dcookie",
	[19] = "eventfd2",
	[20] = "epoll_create1",
	[21] = "epoll_ctl",
	[22] = "epoll_pwait",
	[23] = "dup",
	[24] = "dup3",
	[25] = "fcntl",
	[26] = "inotify_init1",
	[27] = "inotify_add_watch",
	[28] = "inotify_rm_watch",
	[29] = "ioctl",
	[30] = "ioprio_set",
	[31] = "ioprio_get",
	[32] = "flock",
	[33] = "mknodat",
	[34] = "mkdirat",
	[35] = "unlinkat",
	[36] = "symlinkat",
	[37] = "linkat",
	[39] = "umount2",
	[40] = "mount",
	[41] = "pivot_root",
	[42] = "nfsservctl",
	[43] = "statfs",
	[44] = "fstatfs",
	[45] = "truncate",
	[46] = "ftruncate",
	[47] = "fallocate",
	[48] = "faccessat",
	[49] = "chdir",
	[50] = "fchdir",
	[51] = "chroot",
	[52] = "fchmod",
	[53] = "fchmodat",
	[54] = "fchownat",
	[55] = "fchown",
	[56] = "openat",
	[57] = "close",
	[58] = "vhangup",
	[59] = "pipe2",
	[60] = "quotactl",
	[61] = "getdents64",
	[62] = "lseek",
	[63] = "read",
	[64] = "write",
	[65] = "readv",
	[66] = "writev",
	[67] = "pread64",
	[68] = "pwrite64",
	[69] = "preadv",
	[70] = "pwritev",
	[71] = "sendfile",
	[72] = "pselect6",
	[73] = "ppoll",
	[74] = "signalfd4",
	[75] = "vmsplice",
	[76] = "splice",
	[77] = "tee",
	[78] = "readlinkat",
	[79] = "newfstatat",
	[80] = "fstat",
	[81] = "sync",
	[82] = "fsync",
	[83] = "fdatasync",
	[84] = "sync_file_range",
	[85] = "timerfd_create",
	[86] = "timerfd_settime",
	[87] = "timerfd_gettime",
	[88] = "utimensat",
	[89] = "acct",
	[90] = "capget",
	[91] = "capset",
	[92] = "personality",
	[93] = "exit",
	[94] = "exit_group",
	[95] = "waitid",
	[96] = "set_tid_address",
	[97] = "unshare",
	[98] = "futex",
	[99] = "set_robust_list",
	[100] = "get_robust_list",
	[101] = "nanosleep",
	[102] = "getitimer",
	[103] = "setitimer",
	[104] = "kexec_load",
	[105] = "init_module",
	[106] = "delete_module",
	[107] = "timer_create",
	[108] = "timer_gettime",
	[109] = "timer_getoverrun",
	[110] = "timer_settime",
	[111] = "timer_delete",
	[112] = "clock_settime",
	[113] = "clock_gettime",
	[114] = "clock_getres",
	[115] = "clock_nanosleep",
	[116] = "syslog",
	[117] = "ptrace",
	[118] = "sched_setparam",
	[119] = "sched_setscheduler",
	[120] = "sched_getscheduler",
	[121] = "sched_getparam",
	[122] = "sched_setaffinity",
	[123] = "sched_getaffinity",
	[124] = "sched_yield",
	[125] = "sched_get_priority_max",
	[126] = "sched_get_priority_min",
	[127] = "sched_rr_get_interval",
	[128] = "restart_syscall",
	[129] = "kill",
	[130] = "tkill",
	[131] = "tgkill",
	[132] = "sigaltstack",
	[133] = "rt_sigsuspend",
	[134] = "rt_sigaction",
	[135] = "rt_sigprocmask",
	[136] = "rt_sigpending",
	[137] = "rt_sigtimedwait",
	[138] = "rt_sigqueueinfo",
	[139] = "rt_sigreturn",
	[140] = "setpriority",
	[141] = "getpriority",
	[142] = "reboot",
	[143] = "setregid",
	[144] = "setgid",
	[145] = "setreuid",
	[146] = "setuid",
	[147] = "setresuid",
	[148] = "getresuid",
	[149] = "setresgid",
	[150] = "getresgid",
	[151] = "setfsuid",
	[152] = "setfsgid",
	[153] = "times",
	[154] = "setpgid",
	[155] = "getpgid",
	[156] = "getsid",
	[157] = "setsid",
	[158] = "getgroups",
	[159] = "setgroups",
	[160] = "uname",
	[161] = "sethostname",
	[162] = "setdomainname",
	[165] = "getrusage",
	[166] = "umask",
	[167] = "prctl",
	[168] = "getcpu",
	[169] = "gettimeofday",
	[170] = "settimeofday",
	[171] = "adjtimex",
	[172] = "getpid",
	[173] = "getppid",
	[174] = "getuid",
	[175] = "geteuid",
	[176] = "getgid",
	[177] = "getegid",
	[178] = "gettid",
	[179] = "sysinfo",
	[180] = "mq_open",
	[181] = "mq_unlink",
	[182] = "mq_timedsend",
	[183] = "mq_timedreceive",
	[184] = "mq_notify",
	[185] = "mq_getsetattr",
	[186] = "msgget",
	[187] = "msgctl",
	[188] = "msgrcv",
	[189] = "msgsnd",
	[190] = "semget",
	[191] = "semctl",
	[192] = "semtimedop",
	[193] = "semop",
	[194] = "shmget",
	[195] = "shmctl",
	[196] = "shmat",
	[197] = "shmdt",
	[198] = "socket",
	[199] = "socketpair",
	[200] = "bind",
	[201] = "listen",
	[202] = "accept",
	[203] = "connect",
	[204] = "getsockname",
	[205] = "getpeername",
	[206] = "sendto",
	[207] = "recvfrom",
	[208] = "setsockopt",
	[209] = "getsockopt",
	[210] = "shutdown",
	[211] = "sendmsg",
	[212] = "recvmsg",
	[213] = "readahead",
	[214] = "brk",
	[215] = "munmap",
	[216] = "mremap",
	[217] = "add_key",
	[218] = "request_key",
	[219] = "keyctl",
	[220] = "clone",
	[221] = "execve",
	[222] = "mmap",
	[223] = "fadvise64",
	[224] = "swapon",
	[225] = "swapoff",
	[226] = "mprotect",
	[227] = "msync",
	[228] = "mlock",
	[229] = "munlock",
	[230] = "mlockall",
	[231] = "munlockall",
	[232] = "mincore",
	[233] = "madvise",
	[234] = "remap_file_pages",
	[235] = "mbind",
	[236] = "get_mempolicy",
	[237] = "set_mempolicy",
	[238] = "migrate_pages",
	[239] = "move_pages",
	[240] = "rt_tgsigqueueinfo",
	[241] = "perf_event_open",
	[242] = "accept4",
	[243] = "recvmmsg",
	[260] = "wait4",
	[261] = "prlimit64",
	[262] = "fanotify_init",
	[263] = "fanotify_mark",
	[264] = "name_to_handle_at",
	[265] = "open_by_handle_at",
	[266] = "clock_adjtime",
	[267] = "syncfs",
	[268] = "setns",
	[269] = "sendmmsg",
	[270] = "process_vm_readv",
	[271] = "process_vm_writev",
	[272] = "kcmp",
	[273] = "finit_module",
	[274] = "sched_setattr",
	[275] = "sched_getattr",
	[276] = "renameat2",
	[277] = "seccomp",
	[278] = "getrandom",
	[279] = "memfd_create",
	[280] = "bpf",
	[281] = "execveat",
	[282] = "userfaultfd",
	[283] = "membarrier",
	[284] = "mlock2",
	[285] = "copy_file_range",
	[286] = "preadv2",
	[287] = "pwritev2",
	[288] = "pkey_mprotect",
	[289] = "pkey_alloc",
	[290] = "pkey_free",
	[291] = "statx",
	[292] = "io_pgetevents",
	[293] = "rseq",
	[294] = "kexec_file_load",
	[424] = "pidfd_send_signal",
	[425] = "io_uring_setup",
	[426] = "io_uring_enter",
	[427] = "io_uring_register",
	[428] = "open_tree",
	[429] = "move_mount",
	[430] = "fsopen",
	[431] = "fsconfig",
	[432] = "fsmount",
	[433] = "fspick",
	[434] = "pidfd_open",
	[435] = "clone3",
	[436] = "close_range",
	[437] = "openat2",
	[438] = "pidfd_getfd",
	[439] = "faccessat2",
	[440] = "process_madvise",
	[441] = "epoll_pwait2",
	[442] = "mount_setattr",
	[443] = "quotactl_fd",
	[444] = "landlock_create_ruleset",
	[445] = "landlock_add_rule",
	[446] = "landlock_restrict_self",
	[448] = "process_mrelease",
	[449] = "futex_waitv",
	[450] = "set_mempolicy_home_node",
	[451] = "cachestat",
	[452] = "fchmodat2",
	[453] = "map_shadow_stack",
	[454] = "futex_wake",
	[455] = "futex_wait",
	[456] = "futex_requeue",
	[457] = "statmount",
	[458] = "listmount",
	[459] = "lsm_get_self_attr",
	[460] = "lsm_set_self_attr",
	[461] = "lsm_list_modules",
	[462] = "mseal",
	[463] = "setxattrat",
	[464] = "getxattrat",
	[465] = "listxattrat",
	[466] = "removexattrat",
	[467] = "open_tree_attr",
	[468] = "file_getattr",
	[469] = "file_setattr",
	[470] = "listns",
	[471] = "rseq_slice_yield",
};
static const uint16_t syscall_sorted_names_EM_NONE[] = {
	202,	/* accept */
	242,	/* accept4 */
	89,	/* acct */
	217,	/* add_key */
	171,	/* adjtimex */
	200,	/* bind */
	280,	/* bpf */
	214,	/* brk */
	451,	/* cachestat */
	90,	/* capget */
	91,	/* capset */
	49,	/* chdir */
	51,	/* chroot */
	266,	/* clock_adjtime */
	114,	/* clock_getres */
	113,	/* clock_gettime */
	115,	/* clock_nanosleep */
	112,	/* clock_settime */
	220,	/* clone */
	435,	/* clone3 */
	57,	/* close */
	436,	/* close_range */
	203,	/* connect */
	285,	/* copy_file_range */
	106,	/* delete_module */
	23,	/* dup */
	24,	/* dup3 */
	20,	/* epoll_create1 */
	21,	/* epoll_ctl */
	22,	/* epoll_pwait */
	441,	/* epoll_pwait2 */
	19,	/* eventfd2 */
	221,	/* execve */
	281,	/* execveat */
	93,	/* exit */
	94,	/* exit_group */
	48,	/* faccessat */
	439,	/* faccessat2 */
	223,	/* fadvise64 */
	47,	/* fallocate */
	262,	/* fanotify_init */
	263,	/* fanotify_mark */
	50,	/* fchdir */
	52,	/* fchmod */
	53,	/* fchmodat */
	452,	/* fchmodat2 */
	55,	/* fchown */
	54,	/* fchownat */
	25,	/* fcntl */
	83,	/* fdatasync */
	10,	/* fgetxattr */
	468,	/* file_getattr */
	469,	/* file_setattr */
	273,	/* finit_module */
	13,	/* flistxattr */
	32,	/* flock */
	16,	/* fremovexattr */
	431,	/* fsconfig */
	7,	/* fsetxattr */
	432,	/* fsmount */
	430,	/* fsopen */
	433,	/* fspick */
	80,	/* fstat */
	44,	/* fstatfs */
	82,	/* fsync */
	46,	/* ftruncate */
	98,	/* futex */
	456,	/* futex_requeue */
	455,	/* futex_wait */
	449,	/* futex_waitv */
	454,	/* futex_wake */
	236,	/* get_mempolicy */
	100,	/* get_robust_list */
	168,	/* getcpu */
	17,	/* getcwd */
	61,	/* getdents64 */
	177,	/* getegid */
	175,	/* geteuid */
	176,	/* getgid */
	158,	/* getgroups */
	102,	/* getitimer */
	205,	/* getpeername */
	155,	/* getpgid */
	172,	/* getpid */
	173,	/* getppid */
	141,	/* getpriority */
	278,	/* getrandom */
	150,	/* getresgid */
	148,	/* getresuid */
	165,	/* getrusage */
	156,	/* getsid */
	204,	/* getsockname */
	209,	/* getsockopt */
	178,	/* gettid */
	169,	/* gettimeofday */
	174,	/* getuid */
	8,	/* getxattr */
	464,	/* getxattrat */
	105,	/* init_module */
	27,	/* inotify_add_watch */
	26,	/* inotify_init1 */
	28,	/* inotify_rm_watch */
	3,	/* io_cancel */
	1,	/* io_destroy */
	4,	/* io_getevents */
	292,	/* io_pgetevents */
	0,	/* io_setup */
	2,	/* io_submit */
	426,	/* io_uring_enter */
	427,	/* io_uring_register */
	425,	/* io_uring_setup */
	29,	/* ioctl */
	31,	/* ioprio_get */
	30,	/* ioprio_set */
	272,	/* kcmp */
	294,	/* kexec_file_load */
	104,	/* kexec_load */
	219,	/* keyctl */
	129,	/* kill */
	445,	/* landlock_add_rule */
	444,	/* landlock_create_ruleset */
	446,	/* landlock_restrict_self */
	9,	/* lgetxattr */
	37,	/* linkat */
	201,	/* listen */
	458,	/* listmount */
	470,	/* listns */
	11,	/* listxattr */
	465,	/* listxattrat */
	12,	/* llistxattr */
	18,	/* lookup_dcookie */
	15,	/* lremovexattr */
	62,	/* lseek */
	6,	/* lsetxattr */
	459,	/* lsm_get_self_attr */
	461,	/* lsm_list_modules */
	460,	/* lsm_set_self_attr */
	233,	/* madvise */
	453,	/* map_shadow_stack */
	235,	/* mbind */
	283,	/* membarrier */
	279,	/* memfd_create */
	238,	/* migrate_pages */
	232,	/* mincore */
	34,	/* mkdirat */
	33,	/* mknodat */
	228,	/* mlock */
	284,	/* mlock2 */
	230,	/* mlockall */
	222,	/* mmap */
	40,	/* mount */
	442,	/* mount_setattr */
	429,	/* move_mount */
	239,	/* move_pages */
	226,	/* mprotect */
	185,	/* mq_getsetattr */
	184,	/* mq_notify */
	180,	/* mq_open */
	183,	/* mq_timedreceive */
	182,	/* mq_timedsend */
	181,	/* mq_unlink */
	216,	/* mremap */
	462,	/* mseal */
	187,	/* msgctl */
	186,	/* msgget */
	188,	/* msgrcv */
	189,	/* msgsnd */
	227,	/* msync */
	229,	/* munlock */
	231,	/* munlockall */
	215,	/* munmap */
	264,	/* name_to_handle_at */
	101,	/* nanosleep */
	79,	/* newfstatat */
	42,	/* nfsservctl */
	265,	/* open_by_handle_at */
	428,	/* open_tree */
	467,	/* open_tree_attr */
	56,	/* openat */
	437,	/* openat2 */
	241,	/* perf_event_open */
	92,	/* personality */
	438,	/* pidfd_getfd */
	434,	/* pidfd_open */
	424,	/* pidfd_send_signal */
	59,	/* pipe2 */
	41,	/* pivot_root */
	289,	/* pkey_alloc */
	290,	/* pkey_free */
	288,	/* pkey_mprotect */
	73,	/* ppoll */
	167,	/* prctl */
	67,	/* pread64 */
	69,	/* preadv */
	286,	/* preadv2 */
	261,	/* prlimit64 */
	440,	/* process_madvise */
	448,	/* process_mrelease */
	270,	/* process_vm_readv */
	271,	/* process_vm_writev */
	72,	/* pselect6 */
	117,	/* ptrace */
	68,	/* pwrite64 */
	70,	/* pwritev */
	287,	/* pwritev2 */
	60,	/* quotactl */
	443,	/* quotactl_fd */
	63,	/* read */
	213,	/* readahead */
	78,	/* readlinkat */
	65,	/* readv */
	142,	/* reboot */
	207,	/* recvfrom */
	243,	/* recvmmsg */
	212,	/* recvmsg */
	234,	/* remap_file_pages */
	14,	/* removexattr */
	466,	/* removexattrat */
	276,	/* renameat2 */
	218,	/* request_key */
	128,	/* restart_syscall */
	293,	/* rseq */
	471,	/* rseq_slice_yield */
	134,	/* rt_sigaction */
	136,	/* rt_sigpending */
	135,	/* rt_sigprocmask */
	138,	/* rt_sigqueueinfo */
	139,	/* rt_sigreturn */
	133,	/* rt_sigsuspend */
	137,	/* rt_sigtimedwait */
	240,	/* rt_tgsigqueueinfo */
	125,	/* sched_get_priority_max */
	126,	/* sched_get_priority_min */
	123,	/* sched_getaffinity */
	275,	/* sched_getattr */
	121,	/* sched_getparam */
	120,	/* sched_getscheduler */
	127,	/* sched_rr_get_interval */
	122,	/* sched_setaffinity */
	274,	/* sched_setattr */
	118,	/* sched_setparam */
	119,	/* sched_setscheduler */
	124,	/* sched_yield */
	277,	/* seccomp */
	191,	/* semctl */
	190,	/* semget */
	193,	/* semop */
	192,	/* semtimedop */
	71,	/* sendfile */
	269,	/* sendmmsg */
	211,	/* sendmsg */
	206,	/* sendto */
	237,	/* set_mempolicy */
	450,	/* set_mempolicy_home_node */
	99,	/* set_robust_list */
	96,	/* set_tid_address */
	162,	/* setdomainname */
	152,	/* setfsgid */
	151,	/* setfsuid */
	144,	/* setgid */
	159,	/* setgroups */
	161,	/* sethostname */
	103,	/* setitimer */
	268,	/* setns */
	154,	/* setpgid */
	140,	/* setpriority */
	143,	/* setregid */
	149,	/* setresgid */
	147,	/* setresuid */
	145,	/* setreuid */
	157,	/* setsid */
	208,	/* setsockopt */
	170,	/* settimeofday */
	146,	/* setuid */
	5,	/* setxattr */
	463,	/* setxattrat */
	196,	/* shmat */
	195,	/* shmctl */
	197,	/* shmdt */
	194,	/* shmget */
	210,	/* shutdown */
	132,	/* sigaltstack */
	74,	/* signalfd4 */
	198,	/* socket */
	199,	/* socketpair */
	76,	/* splice */
	43,	/* statfs */
	457,	/* statmount */
	291,	/* statx */
	225,	/* swapoff */
	224,	/* swapon */
	36,	/* symlinkat */
	81,	/* sync */
	84,	/* sync_file_range */
	267,	/* syncfs */
	179,	/* sysinfo */
	116,	/* syslog */
	77,	/* tee */
	131,	/* tgkill */
	107,	/* timer_create */
	111,	/* timer_delete */
	109,	/* timer_getoverrun */
	108,	/* timer_gettime */
	110,	/* timer_settime */
	85,	/* timerfd_create */
	87,	/* timerfd_gettime */
	86,	/* timerfd_settime */
	153,	/* times */
	130,	/* tkill */
	45,	/* truncate */
	166,	/* umask */
	39,	/* umount2 */
	160,	/* uname */
	35,	/* unlinkat */
	97,	/* unshare */
	282,	/* userfaultfd */
	88,	/* utimensat */
	58,	/* vhangup */
	75,	/* vmsplice */
	260,	/* wait4 */
	95,	/* waitid */
	64,	/* write */
	66,	/* writev */
};
#endif //__BITS_PER_LONG != 64
static const struct syscalltbl syscalltbls[] = {
#if defined(ALL_SYSCALLTBL) || defined(__alpha__)
       {
	      .num_to_name = syscall_num_to_name_EM_ALPHA,
	      .sorted_names = syscall_sorted_names_EM_ALPHA,
	      .e_machine = EM_ALPHA,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_ALPHA),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_ALPHA),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__alpha__)

#if defined(ALL_SYSCALLTBL) || defined(__arm__) || defined(__aarch64__)
       {
	      .num_to_name = syscall_num_to_name_EM_ARM,
	      .sorted_names = syscall_sorted_names_EM_ARM,
	      .e_machine = EM_ARM,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_ARM),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_ARM),
       },
       {
	      .num_to_name = syscall_num_to_name_EM_AARCH64,
	      .sorted_names = syscall_sorted_names_EM_AARCH64,
	      .e_machine = EM_AARCH64,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_AARCH64),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_AARCH64),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__arm__) || defined(__aarch64__)

#if defined(ALL_SYSCALLTBL) || defined(__csky__)
       {
	      .num_to_name = syscall_num_to_name_EM_CSKY,
	      .sorted_names = syscall_sorted_names_EM_CSKY,
	      .e_machine = EM_CSKY,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_CSKY),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_CSKY),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__csky__)

#if defined(ALL_SYSCALLTBL) || defined(__mips__)
       {
	      .num_to_name = syscall_num_to_name_EM_MIPS,
	      .sorted_names = syscall_sorted_names_EM_MIPS,
	      .e_machine = EM_MIPS,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_MIPS),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_MIPS),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__mips__)

#if defined(ALL_SYSCALLTBL) || defined(__hppa__)
       {
	      .num_to_name = syscall_num_to_name_EM_PARISC,
	      .sorted_names = syscall_sorted_names_EM_PARISC,
	      .e_machine = EM_PARISC,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_PARISC),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_PARISC),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__hppa__)

#if defined(ALL_SYSCALLTBL) || defined(__powerpc__) || defined(__powerpc64__)
       {
	      .num_to_name = syscall_num_to_name_EM_PPC,
	      .sorted_names = syscall_sorted_names_EM_PPC,
	      .e_machine = EM_PPC,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_PPC),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_PPC),
       },
       {
	      .num_to_name = syscall_num_to_name_EM_PPC64,
	      .sorted_names = syscall_sorted_names_EM_PPC64,
	      .e_machine = EM_PPC64,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_PPC64),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_PPC64),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__powerpc__) || defined(__powerpc64__)

#if defined(ALL_SYSCALLTBL) || defined(__riscv)
       {
	      .num_to_name = syscall_num_to_name_EM_RISCV,
	      .sorted_names = syscall_sorted_names_EM_RISCV,
	      .e_machine = EM_RISCV,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_RISCV),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_RISCV),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__riscv)

#if defined(ALL_SYSCALLTBL) || defined(__s390x__)
       {
	      .num_to_name = syscall_num_to_name_EM_S390,
	      .sorted_names = syscall_sorted_names_EM_S390,
	      .e_machine = EM_S390,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_S390),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_S390),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__s390x__)

#if defined(ALL_SYSCALLTBL) || defined(__sh__)
       {
	      .num_to_name = syscall_num_to_name_EM_SH,
	      .sorted_names = syscall_sorted_names_EM_SH,
	      .e_machine = EM_SH,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_SH),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_SH),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__sh__)

#if defined(ALL_SYSCALLTBL) || defined(__sparc64__) || defined(__sparc__)
       {
	      .num_to_name = syscall_num_to_name_EM_SPARC,
	      .sorted_names = syscall_sorted_names_EM_SPARC,
	      .e_machine = EM_SPARC,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_SPARC),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_SPARC),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__sparc64__) || defined(__sparc__)

#if defined(ALL_SYSCALLTBL) || defined(__i386__) || defined(__x86_64__)
       {
	      .num_to_name = syscall_num_to_name_EM_386,
	      .sorted_names = syscall_sorted_names_EM_386,
	      .e_machine = EM_386,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_386),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_386),
       },
       {
	      .num_to_name = syscall_num_to_name_EM_X86_64,
	      .sorted_names = syscall_sorted_names_EM_X86_64,
	      .e_machine = EM_X86_64,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_X86_64),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_X86_64),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__i386__) || defined(__x86_64__)

#if defined(ALL_SYSCALLTBL) || defined(__xtensa__)
       {
	      .num_to_name = syscall_num_to_name_EM_XTENSA,
	      .sorted_names = syscall_sorted_names_EM_XTENSA,
	      .e_machine = EM_XTENSA,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_XTENSA),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_XTENSA),
       },
#endif // defined(ALL_SYSCALLTBL) || defined(__xtensa__)
       {
	      .num_to_name = syscall_num_to_name_EM_NONE,
	      .sorted_names = syscall_sorted_names_EM_NONE,
	      .e_machine = EM_NONE,
	      .num_to_name_len = ARRAY_SIZE(syscall_num_to_name_EM_NONE),
	      .sorted_names_len = ARRAY_SIZE(syscall_sorted_names_EM_NONE),
       },
};
