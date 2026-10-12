# ProcessDesk

A configurable application-only distribution of [System Informer](https://github.com/winsiderss/systeminformer), built on GitHub's hosted Windows runner. Normal and administrator operation are supported; connecting to or loading the kernel driver is disabled in this distribution. The existing System Informer installation and its driver are not modified.

## Download

Open [Releases](https://github.com/AbdelrahmanMohamedDesoky/processdesk/releases/latest) and download the `ProcessDesk-...-x64-setup.exe` installer, or the portable ZIP. Build tools and certificates are not needed on your PC. The binaries are unsigned.

The installer uses a separate directory, uninstall identity, and settings location. It does not register a driver, replace Windows Task Manager, or configure startup. Settings are preserved on uninstall. The upstream updater is excluded so it cannot replace this application with the stock distribution.

Optional online scanning stays off by default, and its first-run partner popup is suppressed. Configure online scanning explicitly in the plugin's options if you want it.

## Automatic builds

The workflow resolves the upstream reference in `branding.json` to an exact commit. It builds only when that commit or the build recipe changes. Successful validation produces a versioned release; a failure leaves the last successful release available. A failed build can be retried. Published releases are never overwritten.

During initial commissioning, scheduled checks run every five minutes. After a real scheduled run is verified, this will change to daily checks. GitHub may delay scheduled runs and disables public-repository schedules after 60 days without repository activity; re-enable the workflow from its Actions page if needed.

To build manually, open **Actions → Build and release → Run workflow**. Leave `upstream_ref` blank for the configured branch, or supply a branch, tag, or commit. `force` rebuilds a published revision as an artifact without overwriting its release. `baseline` compiles an application-only baseline and does not publish.

Checksums, the upstream commit, pipeline revision, build tool versions, a source modification patch, and installer validation results accompany every release. Installation, application launch, all packaged plugins, installation over an existing copy, and uninstall are exercised on the disposable Windows runner. This does not establish compatibility with any particular game or anti-cheat; that requires local acceptance testing.

## Rename

Edit `display_name`, `app_id`, and `publisher` in `branding.json`. Names currently use simple ASCII characters; `app_id` must contain letters and digits without spaces. The executable, file metadata, main window, settings directories, shortcuts, and installer are derived from that configuration.

The installer GUID remains stable so upgrades retain a single product identity. Changing `app_id` also changes the default installation and settings locations; migration of an already-installed copy should be reviewed separately.

## Maintenance

Critical upstream source changes cause a clear branding-contract failure rather than a silently incomplete patch. Fix the recipe in this repository, then rerun. Read **Actions** for failures. If publishing is interrupted after draft creation, review that draft before retrying.

Standard hosted runners are free for public repositories. Workflow artifacts expire after three days; published release assets remain available. No paid runners or external signing service are configured. Only the publishing job receives repository write permission. GitHub Actions dependencies are pinned to commits.

The project keeps source/API identifiers and copyright attribution that are needed for compatibility and license compliance. It does not claim to remove every recognizable pattern or guarantee detection outcomes.

## License and provenance

Automation in this repository is MIT licensed. The application derives from System Informer and retains its MIT license, copyright notices, and third-party licenses. The workflow downloads the recorded upstream revision, applies the reviewed build recipe, and distributes its generated `branding.patch` alongside the binaries.
