# Huddle

A WoW Forever addon that makes the Battle.net friends list dense: one line per friend instead of a big card, so
you can see 20 friends at once. You can show only the friends you can invite, or only those on your realm, or one class, and sort by
level or name.

## What it shows

- **One line per friend:** status, account name (favourites starred), level, and the character in its class colour.
  Friends in another game show what they're playing; offline friends show when they were last on. The zone, the
  realm and the note are in the tooltip.
- **The invite button** on the right: a check if they're already in your group, the invite icon if you can invite
  them, greyed if you can't (the tooltip gives the reason, like "not allied"). Its tooltip says what a click will do:
  Invite, Suggest invite (you're in a group but not its leader) or Request to join (they're in a group).
- **Filters** on the bar, each with a count: **Invitable** (only friends you can invite), **My realm**, **Offline**
  (offline friends too, the most recently online first).
- **Sorts:** **Level** (60 to 1; click again for 1 to 60) and **Name**.
- **Class icons:** one per class. An icon is lit when friends of that class are in the list, and its tooltip gives counts
  ("Priest: 3 friends, 1 invitable"). Click to show only that class; several classes work; right-click or **All**
  to show every class again. The class filter resets when you log in.
- Blizzard's search box still works on the list.
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
