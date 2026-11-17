# Reflect on the week

Keep the household's memory true to how they live, so next week's planning fits them better.

1. Call `get_context` for the memory as it stands and `get_planning_history` for the last six
   weeks: what was planned, skipped, removed and chosen again.
2. Look for patterns that will still matter next week: a weekday they skip, a dish they always
   swap away, a favourite they come back to, leftovers they plan on. One week is not a pattern;
   three in six is.
3. Write what you find with `update_memory`, as one short, specific fact per entry in plain words
   ("Hoppar ofta över middagen på torsdagar", not "thu_dinner skipped 4/6"). Who they are goes in
   `profile`; what has been learned goes in `notes`.
4. When a fact has changed, `patch` its entry; when it's no longer true, `remove` it. Past 80%
   full, merge entries in the same batch you add to.

Most weeks little or nothing needs to change. Then change nothing and say so.
