# Plan next week

Fill every empty dinner next week (Monday to Sunday after today) with a recipe this household
will actually eat. Leave days that already have a meal, pinned days and eating-out days as they
are.

1. Call `get_context` and `get_planning_history`. The history shows what they choose again, what
   they swap away, and which days they skip; plan for the household they are, not the one a
   recipe site imagines. The memory says the same in their own words.
2. Prefer what's in the pantry and due soon, and this week's deals (`list_deals`). Keep within
   the weekly budget when one is set.
3. Find recipes with `search_recipes` and read one with `get_recipe`. If what they have would
   repeat itself too much, find one or two new dinners on the web that fit them, and save them
   with `save_recipe` (`recipe_type` meal).
4. Put each on its day with `set_dinner`, by ISO date. Plan leftovers onto the next day where it
   makes sense, as they do themselves.
5. Make the shopping list with `make_list`.
