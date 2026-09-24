# Improved Tunnelers

Tunnelers share breaches, continue towards the enemy campfire, target walls, towers and gates, and restore the ground after collapse. Collapse damage, nearby building damage and a temporary building restriction are configurable. Digging units can be excluded from selection and enemy targeting. Above ground, tunnelers gain the attack-here button, respond to defensive/aggressive stances and can join AI raids configured with Tunneler raid units.

Gameplay features default to ON when the module is selected; diagnostics default to OFF. Configure them under Customizations → Improved Tunnelers. Runtime and UI defaults agree: 120 seconds of building restriction and 60 nearby-building damage. Explicit saved values remain in effect. Restart the game after changing settings.

Starting tunnelers are a separate, optional AI Swapper 1.5.0 feature. Improved Tunnelers does not spawn starting troops and does not require AI Swapper. To add them, enable an AI slot's Starting troops component in AI Swapper and set its Normal, Crusader or Deathmatch tunneler count, then start a new match. Unset counts use the selected AI pack; ordinary packs add none. Loading a save does not add troops. Fixed Engineers is independent and fixes siege crew cleanup/dismounting.

Quick single-player test: recruit a tunneler and compare its response to a nearby enemy with Stances ON/OFF. For raids, use an AI with a Tunneler's Guild and Tunneler in its raid settings. Test starting counts through AI Swapper separately. Do not enable the older Unit Behaviour Fixes tunneler-response patch alongside this module. This integration is a test candidate; new in-game validation and human translation review remain pending.

Version 1.7.0 requires Map Extensions 1.1.5. Start a new match: older saves lack the tunneler state and are rejected. Keep the same module packages and settings when reloading or replaying. Pending collapses, routes and building restrictions are now saved. To test, save during a collapse, reload, and compare with uninterrupted play. End-to-end replay validation is still pending.

A save renamed to .map can still be opened and edited as a scenario. Maps start with fresh tunneler state; ordinary saves restore ongoing work.
