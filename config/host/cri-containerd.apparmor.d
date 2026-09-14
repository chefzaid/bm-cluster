# K3s/containerd runtime-default profile with Ubuntu AppArmor stacking support.
#
# New Ubuntu kernels force profile changes requested by an unprivileged,
# unconfined runc process to stack with "unconfined". Container processes then
# have either of these labels:
#
#   cri-containerd.apparmor.d
#   cri-containerd.apparmor.d//&unconfined
#
# The upstream containerd profile only permits signals and ptrace between the
# first form. The two additional peer rules below preserve the same-container
# boundary while allowing programs such as Karma/Chrome and Go tools to manage
# their own child processes under the stacked label.

abi <abi/3.0>,
#include <tunables/global>

profile cri-containerd.apparmor.d flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  network,
  capability,
  file,
  umount,

  # Host processes and the OCI runtime may stop container processes.
  signal (receive) peer=unconfined,
  signal (receive) peer=runc,
  signal (receive) peer=crun,

  # Processes may manage only peers carrying this runtime profile, including
  # the Ubuntu-enforced stacked variant.
  signal (send,receive) peer=cri-containerd.apparmor.d,
  signal (send,receive) peer=cri-containerd.apparmor.d//&unconfined,

  deny @{PROC}/* w,
  deny @{PROC}/{[^1-9/],[^1-9/][^0-9/],[^1-9s/][^0-9y/][^0-9s/],[^1-9/][^0-9/][^0-9/][^0-9/]*}/** w,
  deny @{PROC}/sys/[^k]** w,
  deny @{PROC}/sys/kernel/{?,??,[^s][^h][^m]**} w,
  deny @{PROC}/sysrq-trigger rwklx,
  deny @{PROC}/kcore rwklx,

  deny mount,

  deny /sys/[^f]*/** wklx,
  deny /sys/f[^s]*/** wklx,
  deny /sys/fs/[^c]*/** wklx,
  deny /sys/fs/c[^g]*/** wklx,
  deny /sys/fs/cg[^r]*/** wklx,
  deny /sys/firmware/** rwklx,
  deny /sys/devices/virtual/powercap/** rwklx,
  deny /sys/kernel/security/** rwklx,

  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,
  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d//&unconfined,
}
