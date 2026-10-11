# Backlog (balance / design follow-ups)

Open items that were found by studies but deliberately NOT changed yet. Each needs its own investigation and an owner decision before
any tuning. Nothing here is scheduled; do not fold these into an unrelated release.

## 1. Pressure-spawn system (`scripts/enemy_manager.gd`, `_check_pressure_spawn`)
- Behaviour today: after 30 s without player damage (`PRESSURE_THRESHOLD`) it can fire every 5 s (`PRESSURE_CHECK_INTERVAL`), spawning one buffed
  enemy (Mage preferred) at the nearest type-3 spawn point more than 8 m away. It ignores the population cap and the room cap and forces the
  maximum 2.25x buff (`buff_cap`). Intent (code comment): "the dungeon punishes turtling". It dates from the initial commit and has never been
  tuned for the opening minute; a flawless player can accumulate roughly 11-17 maximum-buffed enemies in 90 s.
- Ideas to consider later (NOT decided): arm it only after the first buff pick (as the room locks are), and/or limit it to the natural
  buff level of the day instead of the maximum.
- Evidence so far (v8.1 bad-seed study, 7 seeds x 3 modes, bot at 200 HP): it did NOT materially cause the observed early deaths. It dealt 0
  damage in 21 runs of 120 s (8 HP in one earlier pass); where it fired, the run was otherwise undamaged. Disabling it, or not forcing the
  maximum buff, did not change the outcome beyond run-to-run variance. Its risk is latent (late, for players who stay undamaged), not proven.

## 2. Fireball traps / mines (`scripts/trap_manager.gd`)
- Roughly 60 traps per run (`trap_count` 50 + `fireball_trap_count` 10 guaranteed fireball mines); no start-area exclusion.
- The fireball mine removes 50% of the player's MAX health immediately (so 100 HP at 200 HP) and then spawns homing fireballs
  (`homing_fireball_damage` 15 base, each hit roughly 11-13 HP in the study) that keep connecting.
- Evidence so far: in the same study traps were about 47% of all damage in the first 120 s (22% to 60% depending on the run) and produced
  some of the largest short bursts. The scripted bot walks quickly through trap tiles, so its exposure probably overstates a human's.
  Needs a separate physical test / balance investigation before anything is changed (count, placement, a start-area exclusion, the 50% rule,
  fireball damage and homing).

## 3. Design items from the game-feel audit (kept OUT of `docs/GAME_FEEL.md` on purpose)
Each changes what the game asks of the player, so each needs an owner decision:
- **The buff pick has no choice**: a reel the player stops, so the outcome is luck plus timing; offering e.g. 2-3 cards to choose from would be a
  design change (and a large UI one).
- **Positive globes**: the audit asked for good globes alongside the curses; adding them changes the risk balance of the globe system.
- **Fireball mine fairness**: no start-area exclusion, 50% of max health at once (see section 2).
- **Potions on a win**: the victory path pays no potions, the death path pays 1 per 50 kills.
- **Loot from culled enemies**: day culls and room-lock culls retire far-off enemies through the normal death path, which still rolls potion / key drops.

## Related, already decided
- Starting health: Barbarian 200 (was 150), Mage 135 (was 100), shipped as OTA v8.2 (health only; no other balance change in that release).
- Ordinary-enemy concentration around the player (seed 106-type openings) remains the other early-damage driver; health only postpones it.
