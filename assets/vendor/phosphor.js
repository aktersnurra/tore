// Makes "ph-NAME", "ph-NAME-fill" and "ph-NAME-duotone" classes from the Phosphor icons kept in
// ./phosphor (MIT, https://phosphoricons.com). Only the icons the app uses are kept there; add a
// file from the Phosphor release to use another. Each icon is a mask over currentColor, so it
// takes the text colour, and a duotone icon's light half shows at the icon's own 20% opacity.
const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = plugin(function({matchComponents, theme}) {
  const iconsDir = path.join(__dirname, "phosphor")
  const values = {}

  for (const weight of ["regular", "fill", "duotone"]) {
    for (const file of fs.readdirSync(path.join(iconsDir, weight))) {
      const name = path.basename(file, ".svg")
      values[name] = {name, fullPath: path.join(iconsDir, weight, file)}
    }
  }

  matchComponents({
    "ph": ({name, fullPath}) => {
      const content = encodeURIComponent(fs.readFileSync(fullPath).toString().replace(/\r?\n|\r/g, ""))
      const size = theme("spacing.6")
      return {
        [`--ph-${name}`]: `url('data:image/svg+xml;utf8,${content}')`,
        "-webkit-mask": `var(--ph-${name})`,
        "mask": `var(--ph-${name})`,
        "mask-repeat": "no-repeat",
        "mask-size": "100% 100%",
        "background-color": "currentColor",
        "vertical-align": "middle",
        "display": "inline-block",
        "flex": "none",
        "width": size,
        "height": size
      }
    }
  }, {values})
})
