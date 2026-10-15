# Security

## Official source

The only official ATV Companion is this GitHub repository and the files attached to its
[Releases](../../releases). The install, change-TV and uninstall commands in the README
download from those releases only.

ATV Companion is open source (MIT license), so anyone may copy and modify it. That also
means copies can exist that do something else. The project can't vouch for them: only run
versions you got from here, and read the script before you run it.

## What ATV Companion can and can't do

- It controls the TV only through network ADB, which the TV allows only for computers you
  approved with "Allow". You can revoke that on the TV (Developer options → Revoke USB
  debugging authorizations).
- The full install runs as Windows' low-privilege Local Service account. Its program files
  can only be changed by administrators; its settings folder only by administrators and
  the service itself.
- It sends nothing anywhere except to your TV. The only internet download is Google's adb
  (platform-tools), during install, checked to be signed by Google.

## Reporting a problem

If you find a security problem, please report it privately through
[GitHub's private vulnerability reporting](../../security/advisories/new) rather than in a
public issue.
