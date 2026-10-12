# Branch and recovery ledger

Read-only forensic audit of this repository, 2026-10-12, under `docs/SOURCE_OF_TRUTH.md` section 3. Authoritative line at the time of the audit:
branch `ccr-5f32885a-gvu16v`, commit after the audit merge (see `git log`); it contains `origin/main`, all release tags and every other branch.

Refresh the branch table with `python3 tools/source_audit.py ledger --auth <ref> --write <file>`; `--check` fails on unaccounted unmerged work.

## Result in one paragraph

No completed work was found outside the authoritative line. Every one of the 33 remote branches, all 16 tags (v1-v8, ota-dev-000001..7, the pointer tag) and all 28
local branches are ancestors of it or patch-equivalent to it. The only thing that was ever out of line was `origin/main` itself: it still points at the old v2.5
upload snapshot plus two owner uploads whose content is already in the line (recorded now by a content-neutral merge). Eight agent worktrees are clean. Of 67
unreachable commits, 63 are dropped `git stash` entries and throwaway end-to-end test fixtures and 4 are superseded drafts of commits that exist in rewritten form;
four stash entries held content that is in no commit and were judged superseded or throwaway (section 4). Nothing needs recovering; nothing was deleted.

## 1. Remote branches against the authoritative line

Ahead = commits the branch has that the line lacks; Behind = commits the line has that the branch lacks. `ota/dev/<sha>` are the immutable OTA publication refs
(each is the exact source of one OTA; they are provenance, keep them).

| Branch | Tip | Date | Ahead | Behind | Disposition |
|---|---|---|---|---|---|
| `android-port` | 93702f8 | 2026-10-05 | 0 | 225 | integrated |
| `ccr-5f32885a-gvu16v` | 01b82fb | 2026-10-11 | 0 | 3 | integrated |
| `checkpoint/pre-ui-brand-93702f8` | 93702f8 | 2026-10-05 | 0 | 225 | integrated |
| `checkpoint/v6-candidate-23cdb6b` | 23cdb6b | 2026-10-05 | 0 | 160 | integrated |
| `main` | f0eaa47 | 2026-10-05 | 0 | 272 | integrated |
| `ota-chain` | a9168e1 | 2026-10-05 | 0 | 159 | integrated |
| `ota/dev/0e1d11095e8a2196abed3e1c4d1d9261bc5678da` | 0e1d110 | 2026-10-07 | 0 | 27 | integrated |
| `ota/dev/0f3dc9ad1a939052ff06de27c05c233e0fd09b56` | 0f3dc9a | 2026-10-07 | 0 | 26 | integrated |
| `ota/dev/1e0e97b85ea1810776fc40dfa7a4ef8fa5a3ced4` | 1e0e97b | 2026-10-07 | 0 | 28 | integrated |
| `ota/dev/3c9ee9f7b6b9d4c986dc31902bc243aeac15a93e` | 3c9ee9f | 2026-10-08 | 0 | 20 | integrated |
| `ota/dev/40abff25f8c24c200b68c6a37f21c0b94c1f97c8` | 40abff2 | 2026-10-11 | 0 | 11 | integrated |
| `ota/dev/66b884d7e7649c6c146544600f09a6d6c1d034a3` | 66b884d | 2026-10-06 | 0 | 59 | integrated |
| `ota/dev/6dd77bea6c73b5c677b0e6f7d0144ee7e72cd567` | 6dd77be | 2026-10-06 | 0 | 93 | integrated |
| `ota/dev/9712819ec53c57211f0ca1fa42e76570b73d1427` | 9712819 | 2026-10-08 | 0 | 25 | integrated |
| `ota/dev/a8de90b442161c86d127e5857e94050534d7c911` | a8de90b | 2026-10-11 | 0 | 10 | integrated |
| `ota/dev/a9099a40c0dec8fd65ea5b2ca18c0019e6d62500` | a9099a4 | 2026-10-11 | 0 | 7 | integrated |
| `ota/dev/ae7e4badfcbff35344a6db24930dc80debf01030` | ae7e4ba | 2026-10-11 | 0 | 12 | integrated |
| `ota/dev/e6fd6ec7df88e1d7ae14e95df2356241ee1e9406` | e6fd6ec | 2026-10-08 | 0 | 19 | integrated |
| `post-v7-2-round` | f2328f1 | 2026-10-07 | 0 | 30 | integrated |
| `promote/v1/37143051773/073e34b9f2976f2336aedb6311bd2da33282eb17/notlatest` | 18e331a | 2026-10-04 | 0 | 249 | integrated |
| `promote/v2/37152299390/ef24eb4cf184dbc61f0d11f7d8b81aca2ab1a88c` | 04e1684 | 2026-10-04 | 0 | 248 | integrated |
| `purgatory-stabilization-round2` | 18d82fa | 2026-10-05 | 0 | 243 | integrated |
| `release/v3` | 18d82fa | 2026-10-05 | 0 | 243 | integrated |
| `release/v4` | 53e92ab | 2026-10-05 | 0 | 226 | integrated |
| `release/v5` | 7b5112b | 2026-10-05 | 0 | 196 | integrated |
| `release/v6` | a9168e1 | 2026-10-05 | 0 | 159 | integrated |
| `release/v7` | af11f45 | 2026-10-06 | 0 | 105 | integrated |
| `release/v8` | f2328f1 | 2026-10-07 | 0 | 30 | integrated |
| `ui-brand` | 7b5112b | 2026-10-05 | 0 | 196 | integrated |
| `v7-1-ota` | 479457b | 2026-10-06 | 0 | 92 | integrated |
| `v7-2-ota` | 66b884d | 2026-10-06 | 0 | 59 | integrated |
| `v7-ota` | af11f45 | 2026-10-06 | 0 | 105 | integrated |
| `v8-1-ota` | e6fd6ec | 2026-10-08 | 0 | 19 | integrated |

`main` shows "integrated" after the ancestry merge `790476a`; before it, its two commits were patch-unique only because they were never recorded as ancestors.

## 2. Tags and release references

| Tag | Commit | Disposition | Commit subject |
|---|---|---|---|
| `v1` | 073e34b | integrated (ancestor) | CI: record the real head commit SHA in build info and artifact name |
| `v2` | ef24eb4 | integrated (ancestor) | Docs: round-2 findings, dispositions and test coverage |
| `v3` | 18d82fa | integrated (ancestor) | Add the canonical Hot Attic Games logo to the v3 candidate |
| `v4` | 53e92ab | integrated (ancestor) | test_app_lifecycle: do not assume slot 0 is empty (shared scratch in t |
| `v5` | 7b5112b | integrated (ancestor) | Purgatory Dungeon v5 release commit (version metadata only) |
| `ota-channel-dev` | f0eaa47 | integrated (ancestor) | Add files via upload — pointer release; the tag sits on the default branch head (f0eaa47) because the release was created there; its content is the moving OTA pointer, not source |
| `v6` | a9168e1 | integrated (ancestor) | Purgatory Dungeon v6 release commit (version metadata only) |
| `v7` | af11f45 | integrated (ancestor) | Purgatory Dungeon v7 release commit (version 7, runtime relock, releas |
| `ota-dev-000001` | 6dd77be | integrated (ancestor) | tests: generation 'exhaust' case no longer depends on one seed's layou |
| `ota-dev-000002` | 66b884d | integrated (ancestor) | Props: furniture-group pieces are checked against walls like wall furn |
| `v8` | f2328f1 | integrated (ancestor) | docs/.gdignore: Godot must not import or export anything under docs/ ( |
| `ota-dev-000003` | 0f3dc9a | integrated (ancestor) | Run the floor-mesh repairs before the worker-thread prop loads start ( |
| `ota-dev-000004` | 9712819 | integrated (ancestor) | v8.2: starting health Barbarian 150 -> 200, Mage 100 -> 135 (health on |
| `ota-dev-000005` | e6fd6ec | integrated (ancestor) | test_enemy_pooling: a reborn enemy already in attack range may begin i |
| `ota-dev-000006` | 40abff2 | integrated (ancestor) | ota_build_payload: list the payload to a file before 'head' (a listing |
| `ota-dev-000007` | a9099a4 | integrated (ancestor) | test_physics_queries: pick the test spot clear both ways and re-verify |

Every release (v1-v8) was built from a commit in this one history; no release was built from an abandoned line.

## 3. Local branches and worktrees

28 local branches, none with unique work: the long-lived ones (`android-port`, `ui-brand`, `v7-ota`, `v7-1-ota`, `v7-2-ota`, `v8-1-ota`, `post-v7-2-round`,
`ota-chain`, `purgatory-stabilization-round2`) are ancestors of the line; `juice-pass` and `pkg-b-about-ota-overlay` are fully contained; the 15 `worktree-agent-*`
branches are agent scratch branches whose tips are all in the line. `main` (local) is 2 commits behind `origin/main`. Eight agent worktrees under `.claude/worktrees/`
were inspected: all clean. One of them, `worktree-agent-a516a6a736be3364b`, was created at `origin/main` (f0eaa47): worktrees are cut from the default branch, which is why a
worktree agent in this session started on the v2.5 snapshot and could not run the project's tests. Moving `main` to the authoritative line fixes this at the root;
until then agents run `tools/source_audit.py base-check`.

## 4. Unreachable commits (objects no branch, tag or reflog points to): 67

| Kind | Count | What it is | Disposition |
|---|---|---|---|
| Dropped `git stash` entries (`WIP on` / `index on`) | 36 | 32 hold only content that is in reachable commits | already integrated |
| ... of which content is in no commit | 4 | `374c5e85` (touch aim-smoothing removal, 2026-10-08), `f5b2f7ca` (trap fireball pass-through, 2026-10-04), `12aaa1ab` (debug prints in `test_physics_queries`, 2026-10-06), `1b0853ac` (a test edit redone in `tests/test_juice.gd`, 2026-10-11) | `374c5e85`: the same removal is in the line (no `KEY_AIM_SMOOTH` in HEAD): integrated through an equivalent implementation. `f5b2f7ca`: the same pass-through is in `trap_manager.gd` `_on_homing_hit`: integrated. `12aaa1ab`, `1b0853ac`: throwaway diagnostics / superseded |
| End-to-end test fixtures (`e2e: source commit of OTA n`, `e2e: throwaway OTA key`, `dry run`) | 27 | commits and throwaway keys that `tests/ota_e2e.py` creates; ephemeral by design | not product work |
| Earlier drafts of commits that exist in rewritten form | 4 | `16f1832b` (v7 OTA native layer, boot files differ from the final), `3cbb48ee`, `586cf238`, `c3e2e843` | superseded: reachable counterparts `d500833`, `06e2af3`, `5f43074`; the final boot layer evolved from the draft |

They are garbage-collectable; nothing in them is wanted. They are listed so the decision is on record rather than implicit.

## 5. Files that existed in a release and are gone from the line

All removals were deliberate and recorded by a commit: the old OTA client generation (its scripts, bundle tools, channel files and workflow; commits `06e2af3`, `6c03a92`, `c0cc33b`:
replaced by the native `scripts/boot/` layer), `tools/make_android_icons.gd` (`1ea34c1`: replaced by the gilded launcher icons), compiled Python caches
(`64a2167`), and the aim-pacing probe (`tests/test_aim_pacing.*`, `tools/aim_pacing_probe.*`, commit `b79d1ce`: the ATTACK drag now uses the Classic swipe path). No reverts exist in the history.

## 6. Recovery decisions

| Item | Classification | Disposition |
|---|---|---|
| Work on any branch missing from the line | none found | nothing to recover |
| `origin/main` upload commits `5db8852`, `f0eaa47` (logo, UI concept art) | integrated through an equivalent implementation (identical blobs: root logo; art at `docs/art/PD_Mobile_Control_Art_Reference.png`) | ancestry recorded by merge `790476a` (tree unchanged) |
| `origin/main` is not the line | structural | **owner action**: fast-forward `main` to the line (PR #1), then drop `current_line` from `docs/source_authority.json` |
| Unreachable stash / fixture / draft commits | superseded or throwaway | none; may be garbage-collected |
| Aim smoothing option, first-generation OTA client | intentionally removed | do not restore |
