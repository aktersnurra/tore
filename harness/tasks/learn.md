# Learn names

New ingredient names, or product names from offers and receipts, are at the end of this message.
Read the household's ingredients with `list_ingredients` first.

- **Names** are things someone in the household wrote or ticked off. Say what each one is with
  `learn_ingredients`: the ingredient it's the same as when the household has one (a kind or a
  brand of it: "Mellanmjölk" is "Mjölk", "Arla Mellanmjölk 1,5 %" is "Mjölk"), or none, with its
  shop section and how long it keeps.
- **Products** are names on offers and receipt lines ("KYCKLINGFILÉ 900G"). Say which ingredient
  each one is with `match_products`, or none when nothing fits. Only clear matches: a ready meal
  with chicken isn't chicken.
