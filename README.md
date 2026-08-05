# TMOOC Keep Gear Inventory

A UE4SS Lua mod for **The Mound** that restores your non-treasure gear after a successful extraction.

## Features

- Saves eligible travel bag items during a raid
- Restores saved gear after returning to the Galleon
- Keeps weapons, armor, ammo, consumables, light sources, and selected utility items
- Does not keep treasure items
- Detects player death and discards the saved inventory for that raid
- Retries restoration if the inventory is not ready immediately after loading

## Kept Item Types

- Weapons
- Armor
- Ammo
- Consumables
- Light sources
- Selected utility items such as maps, lanterns, divining rods, medallions, masks, and similar gear
- Native shop items detected from the game's shop item list

## Not Kept

- Treasure items
- False treasure items
- Raid inventory after player death

## Installation

1. Install UE4SS for The Mound.
2. Copy the `TMOOC_KeepGearInventory-main` folder into:

```txt
TheMound/Binaries/Win64/ue4ss/Mods/
