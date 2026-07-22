# TFLint configuration for the module root.
#
# The "recommended" preset matches TFLint's default behaviour; declaring it
# explicitly gives ruleset tweaks a home so lint findings are fixed here (or
# in the code) rather than with inline suppression comments, see AGENTS.md
# ("What not to do").

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
