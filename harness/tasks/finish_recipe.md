# Finish a recipe

A recipe was just saved or changed; which one, and anything more, is at the end of this message.
Read it with `get_recipe`, then do what it needs and nothing else:

1. **Steps.** If it has no steps, or you're told its instructions changed, write its steps from
   its `instructions` and ingredients and save the recipe with `update_recipe`, changing nothing
   else. Steps are single actions in the order a cook does them, numbered from 1 across the
   whole recipe, grouped by a `phase` in capitals (MISE EN PLACE first, then the cooking phases
   in the order they happen, SERVING last). Each names the ingredients it uses exactly as the
   ingredient list does, and a step that waits (simmer, rest, bake) has `duration_minutes`. Keep
   the recipe's language. Leave nothing out and add nothing the recipe doesn't say.

   A meal with `parts` is several dishes cooked together: read each part with `get_recipe` and
   write one order so everything is ready at the same time. Start what takes longest, do the
   quick parts while it cooks or rests, and name each step's phase after its part. Its
   ingredients are its parts'; send them back as `get_recipe` gave them.
2. **Picture.** If it has no picture (`has_picture` is false), or you're told to draw it again,
   draw one with `draw_recipe_picture`. Describe the finished dish as the recipe makes it.

If it already has both and nothing more is asked, do nothing.
