# Connecting C4 Raven servers with Federation Hub

This guide is for the administrator of a C4 Raven server who wants
devices on this server and devices on another server to see each other:
positions, chat and map data.

You do it on Raven's **Federation Hub** page with the **Connect a server**
guide. The other server's admin has to do their part too. This page says
what each of you does.

Contents:

- [Before you start](#before-you-start)
- [How it works](#how-it-works)
- [Only one side connects](#only-one-side-connects)
- [Case A: two Raven servers, each with its own hub](#case-a-two-raven-servers-each-with-its-own-hub-recommended)
- [Case B: Raven and a TAK Server](#case-b-raven-and-a-tak-server)
- [Case C: Raven and another federation hub](#case-c-raven-and-another-federation-hub)
- [What to share: why "Everything"](#what-to-share-why-everything)
- [Reading the page](#reading-the-page)
- [Check connection: every check and its fix](#check-connection-every-check-and-its-fix)
- [Troubleshooting](#troubleshooting)
- [Removing a partner](#removing-a-partner)
- [The Advanced section](#the-advanced-section)
- [Tasks that need a terminal](#tasks-that-need-a-terminal)

## Before you start

1. **Federation Hub is installed on this server.** `install.sh` installs it
   when it finds the TAK.gov download. Otherwise run `./install-fedhub.sh`
   from c4raven-updater (see
   [Tasks that need a terminal](#tasks-that-need-a-terminal)). If the
   Federation Hub page says the hub is down or not answering, fix that
   first.
2. **Port 9102/tcp is open** on the server that is dialled. The installer
   opens 9100-9102 in ufw or firewalld when they are on. A cloud firewall
   or a router port forward you have to open yourself.
3. **Use the exact host name.** Each hub's server certificate is issued for
   exactly one name or IP: the answer to the installer's host question.
   The Federation Hub page shows it under **Partners connect to**. The
   other side must connect to that exact name. A different name for the
   same machine (another DNS name, the IP instead of the name, a typo)
   fails the certificate check, and the hub retries forever.
4. **Your devices are in `Fed group`.** Raven only federates users who are
   members of the `Fed group` group (Raven creates it). Add the users whose
   devices should be seen by the other side on Raven's Groups page.
5. **You can reach the other admin** by email or phone. You swap one file
   each and agree who connects to whom.

## How it works

The page shows the same three steps in its **How it works** tiles:

1. **Trust.** Both servers swap certificate authority (CA) files, so each
   one knows the other is genuine.
2. **Connect.** One side dials the other. Only one side should, or the hub
   drops the duplicate connection.
3. **Share.** Choose what flows each way. Everything is the usual choice;
   this server's Groups page decides what leaves it.

When you press **Connect** at the end of the guide, Raven adds the
partner to the hub's active policy and activates it straight away. There
is no separate "apply" step, and other partners stay connected.

## Only one side connects

One server opens the connection (it "dials"). The other one waits and
accepts it. In the guide this is the **Who connects** step:

- **We connect to them**: this hub dials the other server's address and
  port. You type their address. This hub retries every 5 seconds until
  they answer.
- **They connect to us**: this hub does not dial. You give them the
  address shown (this hub's name and port 9102), and they dial you.

Pick the side that can reach the other. The side that dials must get
through the other side's firewall to its federation port. If one server
has a public address and the other does not, the one without dials.

Never set both sides to dial. The hub then sees two connections from the
same partner, drops one as a duplicate, and the link keeps dropping. The
partner card warns about this ("Both servers are dialling each other").

Agree with the other admin who dials **before** either of you presses
Connect. The guide starts on **We connect to them** for a Raven or a hub,
and on **They connect to us** for a TAK Server. Change it if you agreed
otherwise.

### The instructions follow your choice

**Download instructions for the other admin** gives a text file with
your CA, its fingerprint, your address and the other admin's steps. What
it tells them about connecting depends on where you download it:

| Where | What it says about who connects |
|-------|---------------------------------|
| Step 2, **Swap certificates** | Neutral. Nothing is decided yet, so it says to agree which ONE side connects, and gives the steps for both cases. |
| Step 3, **Who connects** | No file here, but a reminder of what to tell them: "Tell *name*'s admin: they must choose **They connect to us**" when you dial, or "they must choose **We connect to them** and enter *your address*" when they dial. |
| Step 5, **Review & connect** | Matches what you chose: the opposite of your choice. If you dial, it tells them to add nothing outgoing. If they dial, it tells them to connect to your address. |
| A partner card, **More actions** > **Instructions for the other admin** | Matches how that partner is actually set up on this hub. Use it to send the instructions again later. |

Send the step 5 file, or the one from the card. Use the step 2 file only
to start the certificate swap before you have decided.

To swap who connects later, remove the partner and connect it again.

## Case A: two Raven servers, each with its own hub (recommended)

Both servers run C4 Raven with Federation Hub installed. Both admins run
the same guide. Below, "Raven 1" dials and "Raven 2" waits. Swap the roles
if Raven 2 is the one that can reach Raven 1.

**Both admins first:**

1. Agree who dials. Raven 2's admin tells Raven 1's admin the address
   under **Partners connect to** on Raven 2's Federation Hub page.
2. Open **Federation Hub** and click **Connect a server**.
3. **Server type:** choose **Raven with its own hub**. Click **Next**.
4. **Swap certificates**, part *1. Give them our certificate*: click
   **Download our CA** and send the file to the other admin.
5. Read **Our fingerprint** to each other over the phone. All Raven hub
   CAs have the same name, so the fingerprint is the only way to tell them
   apart.
6. Part *2. Upload their certificate*: under **Their CA certificate**,
   choose the file the other admin sent you. Check that the fingerprint
   shown matches what they read out. Set **Partner name** (for example
   "Raven North"). Click **Next**.

**Raven 1's admin (dials):**

7. **Who connects:** choose **We connect to them**. In **Their address**
   type Raven 2's address exactly, without `http://`. Leave **Port** at
   9102. Click **Test reachability**. Both lines should be green: "Name
   found" and "Port 9102 is open". The reminder below tells you Raven 2's
   admin must choose **They connect to us**.
8. **What to share:** leave both **What we send them** and **What we accept
   from them** on **Everything**. Leave the switch "Let servers under their
   certificate authority talk to each other" off. Click **Next**.
9. **Review & connect:** read the list of changes. Click **Download
   instructions for the other admin** and send the file to Raven 2's
   admin: it tells them to choose **They connect to us**. Click
   **Connect**.

**Raven 2's admin (waits):**

7. **Who connects:** choose **They connect to us** (the guide starts on
   **We connect to them**, so change it). Click **Next**.
8. **What to share:** leave both on **Everything**. Click **Next**.
9. **Review & connect:** click **Connect**.

After **Connect**, the guide re-runs the connection checks every 3
seconds for up to two minutes. The hub itself retries every 5 seconds.
When "Connected" turns green, you are done. If the other admin has not
finished yet, you see "Waiting for the other side". That is normal: click
**Done**. The partner card turns green when they connect.

It does not matter who presses Connect first. If Raven 2 is already being
dialled when its admin tries **We connect to them**, Raven refuses with
"That server is already connected to us, so we mustn't connect to it as
well. Choose "They connect to us"." Go back to **Who connects** and change
it.

## Case B: Raven and a TAK Server

The other server is a stock TAK Server. Usually the TAK Server dials your
hub. The guide picks this for you.

**On Raven (you):**

1. **Federation Hub** > **Connect a server** > **TAK Server** > **Next**.
2. **Swap certificates:** click **Download our CA** and send it to the
   TAK Server admin. Read them **Our fingerprint**.
3. Under **Their CA certificate**, upload the TAK Server's CA. On a TAK
   Server this is usually `/opt/tak/certs/files/ca.pem`, the CA that issued
   `takserver.jks`. Upload the CA, not the server certificate: Raven warns
   "This is not a certificate authority" if you pick the wrong one. Set
   **Partner name** (for example "County TAK").
4. **Who connects:** leave **They connect to us**. Give the TAK admin the
   address shown. If you choose **We connect to them** instead, the port
   is the TAK Server's federation v2 port, usually 9001, and the TAK admin
   must add no outgoing connection to you.
5. **What to share:** leave **Everything** both ways.
6. **Review & connect:** click **Download instructions for the other
   admin** and send the file to the TAK admin. Click **Connect**.

**On the TAK Server (their admin)** — the instructions file lists these
too, with the connection step matching your choice:

1. **Configuration > Manage Federates > Edit Configuration**: enable
   federation, version 2. Restart TAK Server if it asks.
2. **Manage Federate Certificate Authorities**: upload your hub's CA (the
   file you sent). Check its fingerprint with you.
3. Send you `/opt/tak/certs/files/ca.pem`.
4. If they connect to you: **Add an Outgoing Connection**: address = your
   hub's address exactly as shown under **Partners connect to**, port
   9102, protocol version 2, enabled. If your hub connects to them: add
   **no** outgoing connection, and make sure their federation port (9001
   by default) is reachable from your hub.
5. Under **Active Connections**, open **Manage Groups** for your hub's
   federate. Choose the inbound and outbound groups, for example
   `__ANON__` or their federation group.

**Nothing flows until step 5 is done.** The link shows "Connected" on
both sides, but no data arrives. This is the most common reason a TAK
Server link looks up but is silent.

## Case C: Raven and another federation hub

The other side is a TAK Federation Hub that is not part of a Raven.

**On Raven (you):** run the guide with **Other federation hub**. Swap
certificates as above. Under **Their CA certificate** upload the CA that
issued the certificate their hub presents. In **Who connects**, either
dial their hub (port usually 9102) or let them dial you. Leave **What to
share** on **Everything**. At **Review & connect**, send them the
instructions from **Download instructions for the other admin**, then
click **Connect**.

**On the other hub (their admin):**

1. Trust your CA: in their hub's console, add your CA file as a CA
   (certificate group). Check the fingerprint with you.
2. Send you their hub's CA.
3. In their active policy, add a group node for your CA, with rules both
   ways between it and their own servers. Use "all groups" on those rules
   (see the next section).
4. If they dial: add an outgoing connection to your address, port 9102,
   TLS on, enabled. If you dial: they add nothing for the connection, and
   only make sure their federation port is reachable from your hub.
5. **Save and activate** the policy. Saving without activating changes
   nothing.

## What to share: why "Everything"

The **What to share** step has two boxes:

- **What we send them**: traffic from this Raven that the hub passes on
  to them.
- **What we accept from them**: traffic from them that the hub lets
  through to this Raven.

**Everything** means the hub passes every group in that direction (on the
hub this is an "all groups" rule). It does not mean everything on your
server is sent. Raven only sends the traffic of `Fed group` members. Your
Groups page decides what leaves this server.

Turning on **Only some groups** lets you limit a direction to listed
groups (**Only the groups I list**, **Everything except the groups I
list**, or **Only listed groups, minus blocked ones**). This only works
when the traffic carries federation group names.

**Raven servers do not label their traffic with federation groups.** A
group filter on traffic coming from a Raven matches nothing, so nothing
gets through. No error is shown; data just stops. So:

- For a Raven partner, keep **Everything** in both directions.
- For any partner, keep **Everything** on **What we send them** (that
  traffic comes from Raven).
- A filter on **What we accept from them** only makes sense for a TAK
  Server or hub that uses federated group mapping.

If you set a filter where it cannot work, the guide shows a yellow
warning and the check "Group filters will let data through" warns.

## Reading the page

### Status strip

| Item | What it shows |
|------|---------------|
| **Hub** | **Reachable** or **Not answering**, and the **Active policy** name. |
| **This hub's certificate** | Its name and fingerprint. The download icon is **Download our CA**. |
| **Partners connect to** | The address partners must use. "Unknown: set the hub's address in settings" means `RAVEN_FEDHUB_HOST` is not set (see [terminal tasks](#tasks-that-need-a-terminal)). |
| **This Raven's bridge** | The link that carries this server's devices to and from the hub: **Connected**, **Running, not connected**, **Turned off in settings**, or **Service** *state*. |

Problems for the whole hub appear under the strip:

- **This hub's own certificate is missing from the active policy** (or
  turned off there): a **Repair** button appears. It puts this hub's own
  certificate back into the active policy (or turns it back on) and
  activates it. It changes nothing else.
- **The Federation Hub has no active policy**: nothing passes between
  servers. If the hub has no stored policies, **Repair** creates one. If
  it has stored policies, Repair (and Connect) stop with "No federation
  policy is active on the hub. Activate one of: ..." and show one
  **Activate "*name*"** button per stored policy (**Activate "*name*" and
  try again** where there is something to retry). Pick the policy you
  were using.

### When the hub is down

If the hub does not answer, the page shows **The Federation Hub is down**
(or **The Federation Hub answered with an error**) in place of the
partner list. Partners can't be shown or changed until it answers. The
page tries again every 10 seconds; **Try again now** tries at once. If it
stays down, restart it on the server (see
[terminal tasks](#tasks-that-need-a-terminal)).

### Partner cards

Each partner has a card. Its status badge is one of:

| Status | Meaning | What to do |
|--------|---------|------------|
| **Connected** | The link is up and the hub can exchange data with this partner. | Nothing. |
| **Waiting** | Set up on this hub, but no connection yet. | The other side may still need to finish their part. Send them the instructions again. Run **Check connection**. |
| **Turned off** | Paused. Nothing is exchanged. | Turn the card's switch back on. |
| **Needs attention** | Something is stopping this link. | Run **Check connection** and follow the red lines. |

The card also shows:

- the direction: **We dial** *host:port* or **They dial us**;
- the partner's **Certificate** fingerprint;
- **We send** and **We accept**: **All groups**, *n* **allowed**, *n*
  **blocked**, or **Nothing**. **Nothing** means the active policy has no
  rule for that direction, so the hub blocks all of it. To fix it, click
  **Edit**, go to **What to share**, and in the **Nothing flows this way**
  box click **Choose Everything**, then **Save & apply**;
- **Interconnected**, if servers under the partner's CA may also talk to
  each other;
- **Sent** and **Received** message counts;
- how many live connections there are, or **No live connection**.

Card buttons: **Check connection**, **Edit** (change **Who connects**,
**What to share** and **Partner name**, then **Save & apply**), and the
**More actions** menu with **Reconnect**, **Instructions for the other
admin** and **Remove**. The switch pauses or resumes the partner.

When both sides dial, the card shows a red warning: "Both servers are
dialling each other. The hub drops the duplicate, so the link keeps
dropping." It shows on every card involved, for example on the partner
that dials in and on this hub's own outgoing connection to the same
server. On the card where this hub dials, a button stops it:

- **Stop connecting to them**: on a partner set up with **We connect to
  them**. This hub stops dialling and the partner becomes **They dial
  us**.
- **Remove this outgoing connection**: on a card that is "Not linked to a
  trusted certificate" (see below). This removes the outgoing connection
  from the active policy.

**Reconnect** drops the partner's live connections. They come back by
themselves in a few seconds. Use it after the other side changed
something.

### Unrecognised connections

Connections to the hub that do not match a partner. Often this is this
Raven's own bridge, or a server whose certificate was trusted outside this
page (for example in the hub's own console). Disconnect them from
**Advanced** > **Connections** if needed.

A card that says "Not linked to a trusted certificate" is an outgoing
connection made outside this page, usually in the hub's own console.
Raven can't tell which partner it belongs to. If the other side also
connects to you, remove one of the two: only one side should connect.
See the troubleshooting entry below.

## Check connection: every check and its fix

**Check connection** on a card (and the end of the guide) lists these
checks in order. Each is **Passed**, **Warning**, **Failed** or **Not
applicable**. Click **Run again** after fixing something.

| Check | Fails when | Fix |
|-------|-----------|-----|
| **Their CA certificate is trusted** | "The hub no longer trusts this CA", or (warning) the connection isn't linked to a trusted CA. | "Remove this partner and connect it again with its CA file." For an unlinked connection: "Make sure the partner's CA is added under Advanced > Certificates". |
| **Their CA is in the active policy** | "This partner is disabled, so the hub refuses its connections", or "The partner's certificate isn't in the active policy". Not applicable when we dial them. | Disabled: turn the partner's switch back on ("Enable the partner"). Missing from the policy: remove the partner and connect it again. (The check also suggests **Repair**, but Repair only restores this hub's own certificate.) |
| **We share data with them** | No rule sends our data to them (card shows **Nothing**). | **Edit** the partner, **What to share** > **Choose Everything** > **Save & apply**. If this hub's own certificate is missing, use **Repair**. |
| **We receive data from them** | No rule delivers their data to us. | Same as above. |
| **Group filters will let data through** (warning) | A group filter is set on traffic from Raven. | Choose **Everything**, unless both sides use federated group mapping. See [why "Everything"](#what-to-share-why-everything). |
| **Only one side connects** | We dial them and they also dial us; or this hub dials another hub while a hub this partner trusts also dials in. | Keep only one direction: on the card, **Stop connecting to them** or **Remove this outgoing connection**, or ask the other admin to remove theirs. |
| **Their address resolves** | The name we dial cannot be found. Not applicable when they dial us. | Check the spelling. It must be the exact name in their server certificate. **Edit** > **Who connects** > **Their address**. |
| **Their port is reachable** | The port does not answer from this server. | Ask the other admin to open the port in their firewall, and check the port number (9102 for a hub, usually 9001 for a TAK Server). Use their real address, not a loopback or link-local one. |
| **Connected** | No live connection yet. | If we dial: wait a few seconds; the hub retries every 5 seconds. If they dial: send them the instructions (**More actions** > **Instructions for the other admin**) so they connect. |
| **Data is flowing** (warning) | No messages yet. | Move a device on either side (it must be in `Fed group` on a Raven). A TAK Server also needs **Manage Groups** set for the hub federate. |
| **Their CA isn't about to expire** | Their CA has expired (fails) or expires within 30 days (warning). | Ask the other admin for their new CA, then connect them again with it. |

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Link comes up and drops over and over. Card says "Both servers are dialling each other". | Both sides dial (duplicate connection). Usually both admins chose **We connect to them**. | Card: **Stop connecting to them**. Or the other admin removes their outgoing connection. Keep only one direction. Send the instructions again from **More actions** > **Instructions for the other admin** so they match. |
| Two cards for the same server: one partner that dials in (**They dial us**) and one card "Not linked to a trusted certificate" that **We dial**. Both show the "both sides dial" warning; the hub logs "already exists. Disallowing duplicate". | Someone added an outgoing connection in the hub's own console (or the old page), and the other hub also dials in. Raven can't link that outgoing connection to a certificate. | If the other hub keeps dialling in: on the unlinked card click **Remove this outgoing connection**. If you would rather dial them: ask the other admin to remove their outgoing connection, then remove the unlinked card's connection, **Remove** the other partner (with **Keep their certificate trusted** on) and connect it again with **We connect to them**. |
| **Their address resolves** fails, or **Their port is reachable** fails while the other hub is up. The hub keeps retrying. | Wrong host name. The address must be the exact name in their certificate. | **Edit** > **Who connects** > fix **Their address**. Ask the other admin for the address under their **Partners connect to**. |
| They dial you and fail their certificate check. | They used a different name for your server than the one on your certificate. | Give them the exact address under **Partners connect to**. To change your hub's name, run `./install-fedhub.sh --host NEW_NAME` (then every partner must switch to the new name). |
| A partner is refused, or this Raven's own devices are not federated. "This hub's own certificate is missing from the active policy". | A CA that is trusted but not in the **active** policy is refused. Uploading a CA, or saving a policy without activating it, is not enough. | **Repair** on the status strip for this hub's own CA. For a partner: turn its switch on, or remove and connect it again. In **Advanced** > **Policy editor**, always use **Save & apply**. |
| "The Federation Hub has no active policy". | The active policy was deleted, or never created. | No stored policies: **Repair**. Stored policies: click **Activate "*name*"** in the error box, or open the policy in **Advanced** > **Policy editor** and **Save & apply** it. |
| **Advanced** > **Policy editor** says **This would cut off this Raven** when you apply. | The policy leaves out this server's own certificate node (or turns it off), so the hub would refuse this Raven's own bridge. | Click **Add it back and apply**. It puts the node back with rules both ways to every other server in the policy. Only use **Apply without it anyway…** if you mean to stop this Raven federating. |
| Removing a CA in **Advanced** > **Certificates** says **This CA is still in use**. | The active policy still has nodes for that CA. Removing the CA alone leaves them pointing at an untrusted CA. | Click **Remove them from the policy first**: it removes those nodes and their rules, applies the policy, then removes the CA. For a partner, **Remove** on its card does the same. |
| **Their CA isn't about to expire** fails. | Their CA expired. | Get their new CA. **Remove** the partner (leave "Keep their certificate trusted" off) and connect again with the new file. |
| Federate connections drop every 15 seconds or so when nothing is moving. | The broker's `clientTimeoutTime` is 15 (the package default). It must be 3600. | Run `./install-fedhub.sh` (it sets 3600 and restarts what is needed). Do not edit it back to 15. See [terminal tasks](#tasks-that-need-a-terminal). |
| "The Federation Hub is down" or "Can't reach the Federation Hub". The page retries every 10 seconds. | The hub service is stopped or still starting. | Wait a minute, then **Try again now**. If it stays down: `sudo systemctl restart federation-hub`. If it keeps dying: `./install-fedhub.sh --repair-unit`. |
| **This Raven's bridge** shows **Running, not connected** or a stopped service. "This Raven's own bridge is not connected to the hub". | `fedhub_bridge` is down, or the hub refuses it (own CA missing). | **Repair** if offered. Then `sudo systemctl restart fedhub_bridge`. If it still fails, `./install-fedhub.sh --check` says why; `./install-fedhub.sh` fixes it. |
| **This Raven's bridge** shows **Turned off in settings**. | `RAVEN_FEDHUB_FEDERATE_ENABLE` is off. | Run `./install-fedhub.sh`, which turns it on, or set it in `config.yml` and restart Raven. |
| Connected, but no data. | TAK Server without **Manage Groups** set; a group filter on Raven traffic; or the user is not in `Fed group`. | Set **Manage Groups** on the TAK Server. Set **What to share** to **Everything**. Add the user to `Fed group`. |

## Removing a partner

On the card, open **More actions** > **Remove**. The hub stops exchanging
data with that partner straight away, and the change is activated.

The dialog has a switch, **Keep their certificate trusted**:

- **On**: only the partner is removed. Their CA stays trusted, so other
  partners are not interrupted. Use this if you will reconnect them soon.
- **Off** (default): their CA is removed too. The hub then restarts its
  federation listener, so **every other partner disconnects for a few
  seconds** and reconnects by itself. Do this at a quiet time.

Tell the other admin. If they dial you, their side keeps retrying until
they remove you too.

## The Advanced section

**Advanced**, at the bottom of the page, is closed by default. It holds
everything the hub can do that the guide does not need: the same tools
as the hub's own admin console. Normal setup never needs it.

| Tab | Use it for |
|-----|-----------|
| **Connections** | Every live connection, with **Disconnect**. |
| **Metrics** | The hub's message and byte counters. |
| **Certificates** | Trusted CAs: **Download our CA**, **Add CA** (optionally **Also add it to the active policy**), **Save nickname**, **Remove**. Removing a CA disconnects every partner for a few seconds. If the active policy still uses it, you get **This CA is still in use** and **Remove them from the policy first** (the safe way). |
| **Policy editor** | Edit federation policies by hand: the policy's **Description**, **Rename…**, nodes (CA groups, outgoing connections, token groups, with **Token expiration (ms since 1970)** on a token group), rules, **Group sets**, **Plugin routing** (which federates each hub plugin sends to and receives from), raw JSON, and export. **Save & apply** saves and activates; **Save only** stores without activating. If a policy would leave out this hub's own certificate you get **This would cut off this Raven** with **Add it back and apply**. Never delete the active policy unless you mean to stop all federation. |
| **Tokens** | Generate tokens for token groups in the active policy, for servers that cannot use mutual TLS, and **Revoke** them. Needs a token port on the broker (see below). |
| **Plugins** | Registered plugins, and a read-only view of the plugin routing in the active policy. Edit routing in the **Policy editor**. |
| **Broker** | The broker's settings, read-only (passwords hidden), and **Restart broker**. |
| **Admin access** | Download the `fedhub-admin` admin certificate (after an authenticator-app code) and **Open native console**. |

Prefer `sudo systemctl restart federation-hub` on the host over **Restart
broker**: the button kills the broker from inside the hub, and the service
may restart the whole hub to recover.

## Tasks that need a terminal

These cannot be done from the page. Run them on the Raven server as your
normal sudo-capable user (not root, not `raven`), from
`~/c4raven-updater`. Full details are in
[c4raven-updater's README, "Federation Hub"](https://github.com/C4-Raven/c4raven-updater#federation-hub).

**Install, repair or check the hub:**

```
cd ~/c4raven-updater && git pull --ff-only
./install-fedhub.sh                  # install, or fix whatever is missing; safe to re-run
./install-fedhub.sh --check          # changes nothing; says what is wrong
./install-fedhub.sh --host NEW_NAME  # new host name and certificate; partners must switch to it
./install-fedhub.sh --repair-unit    # old installs whose hub never restarts after a crash
```

**Restart services:**

```
sudo systemctl restart federation-hub    # the hub (needed after a broker yml edit)
sudo systemctl restart fedhub_bridge     # this Raven's bridge to the hub
sudo systemctl restart raven             # Raven itself, after a config.yml change
systemctl status federation-hub fedhub_bridge
```

On a Docker install of the hub, restart its container instead:
`sudo docker ps` to find the `fedhub-...` container, then
`sudo docker restart <name>`.

**Broker settings** (`/opt/tak/federation-hub/configs/federation-hub-broker.yml`
on a `.deb` install): ports, TLS, token servers, `clientTimeoutTime`.
Raven never writes this file, because writing it from the hub's API can
blank the keystore passwords. Edit it on the host and restart the hub:

```
sudo nano /opt/tak/federation-hub/configs/federation-hub-broker.yml
sudo systemctl restart federation-hub
```

Keep `clientTimeoutTime: 3600`. The package default of 15 drops quiet
connections. `./install-fedhub.sh` sets 3600 if it finds 15 or nothing.

**Token ports** (only for a partner that cannot use certificate login,
for example behind a TLS-inspecting firewall): add a token server to the
broker yml, open its port, and restart the hub:

```
# in federation-hub-broker.yml:
#   federationTokenAuthServers:
#     - type: jwt
#       tls: true
#       port: 9103
sudo ufw allow 9103/tcp                  # or: sudo firewall-cmd --permanent --add-port=9103/tcp && sudo firewall-cmd --reload
sudo systemctl restart federation-hub
```

Then make the token under **Advanced** > **Tokens** and give it to the
other admin. They still need your CA.

**Open the federation port** if your firewall is not ufw or firewalld, or
the installer could not:

```
sudo ufw allow 9102/tcp
sudo firewall-cmd --permanent --add-port=9102/tcp && sudo firewall-cmd --reload
```

Cloud security groups and router port forwards are set in the provider's
or router's own console.
