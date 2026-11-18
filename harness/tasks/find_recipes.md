# Find new dinners

Find two dinners on the web that this household doesn't have yet and would actually eat, and
save them. Don't plan them; whoever plans the week will find them.

1. Call `get_context` and `get_planning_history`, and `search_recipes` to see what they already
   have. Look for what would help them: something for what's in the pantry and due soon, a quick
   dinner for the day they struggle with, a new take on a dish they keep choosing, a replacement
   for one they keep swapping away. Not one more of what they already have plenty of.
2. Search the web in the household's language first; their country's recipe sites fit their
   shops and measures. Read the recipe page itself, not a search snippet.
3. Check every ingredient against their diet and allergies before you save.
4. Save each with `save_recipe` (`recipe_type` meal), in the household's language, with
   `source_url`, and `image_url` when the page has its own photo.

In the summary, say for each recipe where it came from and why you chose it for them, and name
any site that refused you or that you couldn't read.
