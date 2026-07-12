---
name: Swedish i18n
description: Internationalize Scullion UI to Swedish using gettext with locale set per user
type: spec
---

# Swedish i18n Design

## Overview

Scullion is a Swedish-only app. All UI strings will be translated to Swedish using the standard Phoenix gettext approach: English source strings in code, Swedish translations in `.po` files. The locale is stored on the user record and set on every request via a plug and LiveView `on_mount` hook.

## Architecture

### Locale plug

A new `ScullionWeb.Plugs.Locale` plug reads `conn.assigns.current_user.locale` (falling back to `"sv"`) and calls `Gettext.put_locale(ScullionWeb.Gettext, locale)`. It is added to the `:browser` pipeline in `router.ex`, after the auth plug so `current_user` is available.

### LiveView locale

`ScullionWeb.Live.Auth` (already used as `on_mount` for all LiveViews) also calls `Gettext.put_locale(ScullionWeb.Gettext, locale)` using the current user's locale field, ensuring LiveView connections get the correct locale.

### User schema

A migration adds `locale :string, default: "sv", null: false` to the `users` table. The `User` schema gets the `locale` field added. All existing users default to `"sv"` via the migration default. No UI to change locale is included in this scope.

## String extraction

Every hardcoded UI string in the live views is wrapped in `gettext("...")`. Modules that don't already import `ScullionWeb.Gettext` get `use Gettext, backend: ScullionWeb.Gettext` added.

After wrapping:

1. `mix gettext.extract` generates/updates the `.pot` file
2. `mix gettext.merge priv/gettext --locale sv` creates `priv/gettext/sv/LC_MESSAGES/default.po` and `errors.po`
3. An LLM pass fills in Swedish `msgstr` values for all entries

A new `priv/gettext/sv/LC_MESSAGES/errors.po` is created with Swedish translations. The existing `priv/gettext/en/LC_MESSAGES/errors.po` is kept as a fallback.

## Files affected

- `lib/scullion_web/plugs/locale.ex` — new plug
- `lib/scullion_web/router.ex` — add plug to `:browser` pipeline
- `lib/scullion_web/live/auth.ex` — set locale in `on_mount`
- `lib/scullion_web/live/*.ex` — wrap UI strings in `gettext()`
- `priv/repo/migrations/*_add_locale_to_users.exs` — new migration
- `lib/scullion/accounts/user.ex` — add `locale` field
- `priv/gettext/sv/LC_MESSAGES/default.po` — new Swedish translations
- `priv/gettext/sv/LC_MESSAGES/errors.po` — new Swedish error translations

## Testing

- Unit test for `ScullionWeb.Plugs.Locale`: verifies locale is set from user record and falls back to `"sv"` when no user is present.
- Existing LiveView tests continue to pass with Swedish translations in place.
