# Atomic deploy opt-in and its safety fixes, on the dummy repo's test host

- Area: atomic deploy (pie/.github is not onboarded; no TEST-AREAS numbering)
- Asana: https://app.asana.com/1/100438094841948/project/1203720326869832/task/1220197417214557
- Automate as: none (needs the real host, its web server and GitHub's runner)
- Last run: not run yet (host unreachable on 2026-11-04; see the PR)

The scripted tests in `tests/` run every workflow on a local stand-in. These steps check what
only a real run shows: GitHub accepting the workflow files, the real host's SSH, rsync and web
server, and the warnings showing up in the Actions UI.

## Precondition

- The dummy repo's test host answers. Its host, SSH user and WordPress root are the `ssh-host`,
  `ssh-user` and `wp-root` in the dummy repo's `.github/workflows/deploy.yml`; this script calls
  them `<host>`, `<user>`, `<wp-root>` and `<site-url>` (the `site-url` there), and does not
  repeat them, because pie/.github is public. `curl -sI <site-url>` gives an HTTP status, not a
  connection error. On 4 Nov 2026 it didn't.
- `pie/dummy-monorepo-for-workflow-testing` has the `SSH_PRIVATE_KEY` secret for the host, and
  its workflow calls this branch's workflows (`@<this branch>` while testing).
- Its upload jobs (`deploy_plugin`, `deploy_plugin_two`, `deploy_theme`, `deploy_migrations`) pass
  `deploy-type: atomic`, as the README example does.
- You can SSH to `<user>@<host>` to look (`ls`), and you know `<wp-root>` (the WordPress root).
- `<plugin>` below is the dummy repo's test plugin directory under `wp-content/plugins/`.

## Steps

1. **Atomic deploy works when opted in.** Actions → Deploy → Run workflow on `main` of the dummy
   repo. Wait for it to finish.
2. **releases/ protected.** Open
   `<site-url>/releases/<first 8 of the commit SHA>/migrations/components.txt`
   in a browser.
3. **Rollback, then deploy (fix B).** Push a trivial commit (call it C) and run Deploy again. Then
   run the Rollback Deploy workflow. Then push another commit (D) and run Deploy again. On the
   host: `ls -la <wp-root>/releases/`. Then run Rollback Deploy once more.
4. **Exposure blocks the swap (fix A).** On the host, in `<wp-root>`, temporarily rename
   `releases/.htaccess` to `releases/.htaccess.off` (so releases/ is served). Push a commit (E)
   and run Deploy. Note what's live: `cat` a file you changed in E under `wp-content/plugins/...`.
   Then rename `.htaccess.off` back to `.htaccess`.
5. **Unknown probe result (amendment).** In the dummy workflow, set `site-url` to a host that
   doesn't resolve (e.g. `https://does-not-exist.invalid`), push a commit (F) and run Deploy. Put
   `site-url` back afterwards.
6. **Leftover .previous (fix C).** On the host, in `<wp-root>`, `mv wp-content/plugins/<plugin>
   wp-content/plugins/<plugin>.previous`. Run Deploy again (re-run of the last good
   commit is fine).
7. **standard unchanged.** Run any existing repo's deploy that uses `deploy.yaml@main` with no
   `deploy-type` (once this reaches main), or point a test caller with no `deploy-type` at this
   branch, and deploy to a scratch path on the host.
8. **Invalid deploy-type.** Point one upload job at `deploy-type: blue` and run Deploy.

## Expected

From the brief (Decisions 1, 2, 7 with its amendment, 8, 9; Definition of done).

1. All jobs green. The plugins and theme on the host match the commit. Releases dir has the new
   `<sha>` with `migrations/deploy-complete.txt`.
2. 403 or 404, not 200 and not the file's contents.
3. After C's deploy, C is live. After the rollback, B (the commit before C) is live. After D's
   deploy, `releases/` holds D and B, not C. The second rollback restores B, not C.
4. The run fails with an `::error::` about releases/ being publicly reachable, in the
   `atomic_deploy` job, **before** any swap: the plugin still has the pre-E content, no
   `.previous` or `.deploying` directories beside it, no maintenance mode.
5. A yellow warning annotation on the run saying the probe couldn't reach the site; F is live
   (the deploy carried on); the run as a whole still ends failed.
6. A yellow warning annotation naming `<plugin>` and saying the `.previous` was put
   back; the deploy finishes green; the plugin is live, no `.previous` left.
7. The job runs the same steps as on main (no "Create destination directory" step), and the
   files arrive as before.
8. The job fails at its first step with a message naming `standard` and `atomic`; nothing is
   built or uploaded.

## Observe at

The Actions run page of the dummy repo (job list, annotations, step logs); the host over SSH
(`ls -la` of `wp-content/plugins`, `wp-content/themes` and `releases/`, `cat` of a changed file);
a browser for step 2.

## Regression

Step 7 is the regression: about 136 callers use `deploy.yaml@main` without `deploy-type`. Their
effective steps are also compared with main's by `tests/deploy-type/test-equivalence.sh`
(`CALLERS_DIR=` runs it over real callers' workflow files).
