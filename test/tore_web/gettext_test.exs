defmodule ToreWeb.GettextTest do
  use ExUnit.Case, async: true

  # gettext shows the English text when a translation is empty or fuzzy, with no error anywhere.
  test "every Swedish string is translated" do
    po = File.read!("priv/gettext/sv/LC_MESSAGES/default.po")

    [_header | entries] = String.split(po, "\n\n")

    untranslated =
      Enum.filter(entries, &(&1 =~ ~r/^msgstr ""$/m and not (&1 =~ ~r/^msgstr ""\n"/m)))

    fuzzy = Enum.filter(entries, &(&1 =~ ~r/^#,.*fuzzy/m))

    assert untranslated == []
    assert fuzzy == []
  end
end
