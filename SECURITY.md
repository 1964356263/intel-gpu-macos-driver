# Security

This is an experimental kernel and graphics driver that runs with relaxed macOS security (SIP and AMFI settings). Do not
install it on a machine that holds data you cannot lose or that others rely on.

If you find a security problem in the code of this repository (for example a kernel memory bug reachable from an
unprivileged process through IntelXe.kext's user client), please report it privately through GitHub's
"Report a vulnerability" button on the Security tab instead of opening a public issue.
