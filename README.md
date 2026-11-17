# TP Classroom 1.0

Watch and help every student computer in your classroom: Macs and Windows PCs on the same network, with no internet needed.

You build everything on your Mac with one command. You get:

| File | Give it to | What happens |
|---|---|---|
| **`TP-Classroom-1.0.0.dmg`** | Macs | Contains **TP Classroom** (teacher) and **TP Classroom Student**. |
| **`TP-Classroom-Setup-1.0.0.exe`** | Windows PCs | One file. Double-click it, choose **teacher** or **student**, type the class code, click **Install**. |

## What version 1 does

1. **One version for everything.** The teacher app updates itself from the internet, then gives that exact version to every student computer over the local network, Mac and Windows. Students never need internet.
2. **Remembers the class.** Computers stay in the teacher's list after quitting, restarting or shutting down, and reconnect by themselves.
3. **Keeps running in the background.**
   - Teacher: closing the window or quitting keeps it running in the menu bar (Mac) or notification area (Windows). Use **Quit TP Classroom Completely** in that icon's menu to really quit. It starts at login.
   - Students: there's no quit button. Only the admin PIN can stop it, and only until the next login.
4. **Works offline, with no IP addresses.** Computers on the same network find each other by themselves. The class code keeps classrooms apart and encrypts everything.
5. **Mac and Windows together.** Any teacher works with any student. ⌘ and Ctrl are swapped automatically, so ⌘C from a Mac becomes Ctrl+C on a PC.
6. **TP AI.** Tell the teacher app what to do in plain words ("shut down all computers") and the AI does it, or looks at a screen and clicks and types there.

Students always know when they're being watched. They see an icon, plus a banner while the teacher is viewing or controlling. Use TP Classroom only on school computers, and tell students about it.

---

## 1. One-time setup on your Mac

You don't need Homebrew or an admin password to build. You need:

- **Apple's build tools.** Check in Terminal with `swift --version`. If it says they're missing, run `xcode-select --install` once. That one step needs an admin password, so without admin ask whoever manages the Mac (or install Xcode from the App Store).
- **Internet the first time.** The scripts download Microsoft's .NET SDK (for the Windows .exe) into `~/.dotnet` and GitHub's `gh` tool into `~/.tpclassroom/tools` by themselves. Neither needs admin.

Then go to the folder:

```bash
cd ~/Downloads/TPClassroom             # wherever you unzipped this
```

Automatic updates are already switched on:

- Your updates repo is ready: **github.com/kornchapattonpoon/tp-classroom-updates** (already set in `config.env`).
- The first build makes your update key by itself and saves it as `~/.tpclassroom/update_private_key`. **Back that file up** (e.g. on a USB drive): apps only accept updates signed with it.
- The first publish asks you to sign in to GitHub once in your browser.

**Recommended:** make a free signing certificate, so Macs keep their permissions after updates.
   1. In Keychain Access, choose **Certificate Assistant → Create a Certificate…**
   2. Set Name to `TP Classroom Signing`, Identity Type to *Self Signed Root*, and Certificate Type to *Code Signing*.
   3. In `config.env`, set `SIGN_IDENTITY="TP Classroom Signing"`.

## 2. Build and publish

For the first version, build and publish in one step (so the apps you install are the same as the ones on GitHub):

```bash
PUBLISH=1 ./scripts/release.sh "First version"
```

Or just build, without publishing:

```bash
./scripts/build.sh
```

```
dist/TP-Classroom-1.0.0.dmg          ← for Macs
dist/TP-Classroom-Setup-1.0.0.exe    ← for Windows
```

Each release also puts the .dmg and .exe on github.com/kornchapattonpoon/tp-classroom-updates/releases for downloading.

## 3. Install

**Teacher's Mac:** open the DMG, drag **TP Classroom** into **Applications**, and open it from there. If you open it from the DMG, it offers to move itself. Choose a class code.

**Student Macs:**
1. Open the DMG and open **TP Classroom Student**.
2. Type the class code and an admin PIN.
3. Click **Install for All Users on This Mac…** and enter an administrator password.
4. Once per Mac, go to **System Settings → Privacy & Security** and turn on **TP Classroom Student** under **Screen Recording** and under **Accessibility**.
5. Log out and back in.

**Windows PCs (teacher or student):**
1. Double-click **TP-Classroom-Setup-1.0.0.exe**.
2. Choose teacher or student, type the class code, and (for students) an admin PIN.
3. Click **Install**, then **Yes** when Windows asks.

It installs for every user, starts at sign-in, adds itself to Windows Firewall, and can be removed from **Settings → Apps**.

**First time on a new computer:**
- macOS may say it can't verify the app. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
- Windows SmartScreen may block the setup. Click **More info → Run anyway**.
- These warnings go away only with paid Apple and Microsoft code-signing certificates.

**Your Mac without admin:** the teacher app installs into the Applications folder inside your home folder and works normally there. Student Macs still need an admin password once for **Install for All Users**.

**Many Macs at once** (Apple Remote Desktop, MDM, Terminal): use `dist/extras/install-student.sh`:
```bash
sudo ./install-student.sh CLASSCODE PIN
```

## 4. In class

- Students appear by themselves. Offline ones stay in the list as "Offline (remembered)".
- **Click a student** to watch them, and turn on **Control** to help. Closing that window turns Control off.
- **Lock All**, **Unlock All**, **Message**, and **Website** work on everyone. Right-click a student to do it for just one, or to **Forget** that computer.
- If the teacher app disappears while screens are locked, they unlock after 45 seconds. The admin PIN also unlocks a screen.
- **TP AI** can do all of this for you, and also shut down or restart computers (see below).

## TP AI

Click **TP AI** in the teacher app (or **Ask TP AI…** in the menu bar / tray) and type what you want, in any language:

- "Shut down all computers" · "Restart iMac-03"
- "Lock every screen with the message: Test starts now"
- "Open google.com on all computers"
- "On PC-07, open Notepad and type Hello" — it looks at that screen, then clicks and types there

**Setup:** get a free key at console.groq.com, then paste it in **Settings → TP AI** (Mac) or **More → Settings → TP AI key** (Windows). It's saved only on that computer and kept through updates. To use a different model or service, change `AI_MODEL` / `AI_BASE_URL` in `config.env` (any OpenAI-compatible API with tools and image input).

Good to know:

- TP AI needs the internet. Everything else in TP Classroom still works offline.
- Screenshots go to the AI service only when TP AI looks at a screen to click or type.
- **Shut down and Restart always ask you to confirm first**, and students get a 15-second warning to save their work.
- When TP AI clicks or types, the student sees the same "being controlled" banner as when you do it.
- Mac students can only be shut down if they were installed with **Install for All Users** (that adds the shutdown permission). Windows students can always be shut down.
- Don't put your key in `config.env` unless you have to: it would be built into the Mac teacher app, which is published on GitHub with every release.

## 5. Releasing an update

GitHub builds and publishes for you (see `.github/workflows/publish.yml`):

1. Change the code and raise `APP_VERSION` in `config.env` (e.g. 1.0.2 → 1.0.3).
2. Push to `main`. GitHub's Macs build the Mac and Windows apps (about 15 minutes) and publish the release. The first line of the commit message becomes "What's new".

One-time setup, in the repo's **Settings → Secrets and variables → Actions**:

| Secret | What to paste |
|---|---|
| `UPDATE_PRIVATE_KEY` | The contents of `~/.tpclassroom/update_private_key` from the Mac that made it |
| `AI_API_KEY` | The TP AI key built into the teacher apps |

You can still publish from your Mac instead: double-click **Publish TP Classroom.command**. A version that's already published is skipped.

Teacher apps install the new version within about two hours (or right away with **Check for Updates**). They wait while you're watching or controlling a student. Then they update every student they see, so all computers match. Afterwards each app shows "Update completed" with what's new, and settings and the remembered class are kept. Every update is checked with your signature before it's installed.

## Troubleshooting

| Problem | Fix |
|---|---|
| A student doesn't appear | Make sure both computers are on the same network and use the same class code. If the network blocks broadcasts, use **More → Connect by Address** once; after that it's remembered. |
| "The class code doesn't match" | Make the codes the same on both computers. |
| Mac: "Local Network access is off" | Go to **System Settings → Privacy & Security → Local Network** and turn TP Classroom on. |
| Mac: black thumbnail / Control does nothing | Turn on Screen Recording / Accessibility for TP Classroom Student, then log out and back in. |
| Mac permissions reset after updates | Set up the signing certificate (step 1.3). |
| Windows: nothing connects | Run the Setup .exe again. It re-adds the Windows Firewall rule. |
| TP AI: "isn't set up yet" | Paste your key in Settings (see TP AI above). |
| TP AI: a Mac won't shut down | Install TP Classroom Student on that Mac again with **Install for All Users**. |
| No .exe was built | Connect to the internet and run `build.sh` again (it downloads the .NET SDK into `~/.dotnet`). |

## Project layout

```
PROTOCOL.md                  the network protocol both Mac and Windows follow
Sources/ClassroomKit/        Mac shared code: protocol, encryption, discovery, updates
Sources/TPClassroomTeacher/  Mac teacher app (SwiftUI + AppKit)
Sources/TPClassroomStudent/  Mac student app (ScreenCaptureKit, CGEvent)
Sources/TPCRelease/          signs packages, the Windows setup exe and the update feed
windows/                     Windows app (C# / .NET 10 WinForms), built on your Mac
scripts/                     build (.dmg + .exe), keys, release, Mac install/uninstall
```
