# Security Policy

## Supported versions

Please report vulnerabilities affecting the latest stable release from
[Mak5er/AirCard Releases](https://github.com/Mak5er/AirCard/releases) or the current
`main` branch. Include the exact version or commit you tested.

Security fixes target the latest release and `main`; backports to older releases
are not promised. If you find a problem in an older version, report it and say
whether it also affects the latest release. Do not repeat a potentially
destructive test just to confirm it.
Fixes, when available, will normally be delivered in a new release. Development
builds and unofficial forks or ports are not covered by a release-support promise.

## Reporting a vulnerability

**Do not publish exploit steps, proof-of-concept files, or sensitive logs in a
public issue, discussion, or pull request.**

1. Open the upstream repository's
   [Security page](https://github.com/Mak5er/AirCard/security).
2. If **Report a vulnerability** is available, use it to send a private report to
   the maintainers. Confirm you are reporting to `Mak5er/AirCard`.
3. If that option is unavailable and the maintainers have not published another
   private contact, open a public issue titled **Private security reporting
   contact requested**. Only ask for a private channel; omit the vulnerability's
   details, affected component, reproduction steps, attachments, and user data.
   Keep the report private until a channel is provided.

A useful private report includes:

- The AirCard release or commit, installation source, macOS version, iOS version,
  and device model. Do not include a device serial number or UDID.
- The affected component, impact, and any required access or user interaction.
- Minimal reproduction steps using a device and data you are authorized to test.
- A small, sanitized proof of concept or relevant log excerpt, if safe to provide.
- Whether the problem has already been disclosed and any proposed mitigation.

## Scope

Relevant reports include unintended code execution, unsafe image or `.passthm`
archive handling, command injection, writes outside intended artwork or theme
paths, applying changes to the wrong device or card, and exposure of local Wallet
metadata, identifiers, or device pairing material. Reports about bundled helpers,
dependencies, and the build or release process are also welcome when they affect
AirCard users.

Routine connection failures, missing-card compatibility, and artwork appearance
problems belong in regular issues unless they have a security impact. Report
vulnerabilities in Apple software or unrelated third-party projects through their
own reporting channels; explain any AirCard-specific impact to this project too.

## Protecting data while reporting and testing

- Remove card numbers, security codes, card or pass identifiers and hashes,
  account names, device identifiers, local usernames and paths, and unrelated
  Wallet activity from screenshots and logs. Hashes can still identify records.
- Never send Apple ID credentials, passcodes, authentication tokens, pairing
  records, full device logs, or device backups. Use synthetic data where possible.
- Test only on devices and accounts you own or have permission to use. Avoid
  disrupting payments, access credentials, or someone else's data.
- Stop if a test risks data loss or unintended device writes. Document what you
  observed rather than extending the test to prove further impact.

## Coordinated disclosure and response

Keep vulnerability details private while the maintainers assess the report and
agree on a disclosure plan. If a report is confirmed, the private discussion can
track a mitigation or fix and an advisory or release note. If it is not accepted,
ask for the reason and provide additional evidence in the same private channel.
Discuss attribution before publishing a reporter's name.

Response and fix timing depend on maintainer availability. There is no guaranteed
acknowledgment or fix deadline, and this policy does not establish a paid bug
bounty. Follow up through the same private channel; if none is available, use only
the contact-request issue described above.
