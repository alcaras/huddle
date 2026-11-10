# Huddle

A WoW Forever addon that makes the Battle.net friends list dense: one line per friend instead of a big card, so
you can see 20 friends at once. You can show only the friends you can invite, or one class, and sort by
level or name.

## What it shows

- **One line per friend:** status, account name (favourites starred), level, and the character in its class colour.
  Friends in another game show what they're playing; offline friends show when they were last on. The zone, the
  ruleset (PvE, PvP, RP, RP PvP) and the note are in the tooltip.
- **Who you can invite stands out:** a friend in the game you can't invite (another faction, another region) has
  their level and character dimmed.
- **The invite button** on the right: a check if they're already in your group, the invite icon if you can invite
  them, greyed if you can't (the tooltip gives the reason, like "not allied"). Its tooltip says what a click will do:
  Invite, Suggest invite (you're in a group but not its leader) or Request to join (they're in a group).
- **Filters** on the bar, each with a count: **Invitable** (only friends you can invite: your faction, your ruleset), **Offline**
  (offline friends too, the most recently online first) and **Favorites** (only your starred Battle.net friends).
  They combine: Favorites with Invitable shows the favorites you can invite, and the counts follow.
- **Sorts:** **Level** (60 to 1; click again for 1 to 60) and **Name**.
- **Zones** (right of the class icons): a grey column with the zone each friend is in, for friends online in the
  game; click again to hide it. Remembered.
- **Role icons** (Tank, Healer, DPS, after the class icons): the roles you tagged your friends with in Blizzard's
  friend menu (right-click a friend, Add Tags > Roles). Click to show only that role (several work: tank or
  healer); it combines with the class icons. Tagged friends show their role icons on their line.
- **Class icons:** one per class. An icon is lit when friends of that class are in the list, and its tooltip gives counts
  ("Priest: 3 friends, 1 invitable"). Click to show only that class; several classes work; right-click or **All**
  to show every class again. The class filter resets when you log in.
- Blizzard's search box still works on the list. It looks at names, characters, your Battle.net notes and the zone
  friends are in: "#tank" finds every friend tagged #tank in their note, "desolace" who is in Desolace, and
  "#tank desolace" the tanks in Desolace (every word must match).
- The list doesn't reorder while your mouse is over it, so a friend logging on can't move the row you're about to
  click.

Click a friend to whisper them; right-click for Blizzard's friend menu (invite, whisper, note, remove ...).

## Commands

- `/huddle off`: Blizzard's own list again (after `/reload`).
- `/huddle on`: Huddle's list again (after `/reload`).

## Install

Download `Huddle-<version>.zip` from [Releases](https://github.com/alcaras/huddle/releases) and unzip it into
`World of Warcraft\_forever_\Interface\AddOns`, so the folder `Huddle` holds `Huddle.toc`.

## How it stays out of trouble

Blizzard's friends list refreshes itself through a protected call, and any addon code inside that refresh gets it
blocked ("Huddle tried to call a protected function"). So Huddle never touches Blizzard's list. It draws its own list
on top, reads your friends itself, and makes Blizzard's list invisible while its own is shown.

World of Warcraft is Blizzard Entertainment's. A fan project, not affiliated with Blizzard.
