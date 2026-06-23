local _ = require("gettext")
return {
    name        = "textolimiti",
    fullname    = _("Textolimiti"),
    description = _([[Mark where the real book text starts and ends so the reading-progress percentage excludes front matter, endnotes and bibliography. Wraps KOReader's custom hidden flows in a keyboard-driven dialog (key N).]]),
}
