-- Shared expectations consumed by both Files and Search contract tests as those
-- adapters arrive. Until then this is a snapshot contract, not provider behavior.
return {
  name = "shared-workspace-file-search-policy-v1",
  policy = {
    hidden = "exclude",
    ignored = "include",
    symlinks = "internal",
    include = { "src/**", "*.md" },
    exclude = { "vendor/**", "build/**" },
  },
  expectations = {
    hidden_file = false,
    ignored_source_file = true,
    external_symlink = false,
    included_markdown = true,
    vendor_file = false,
  },
  entries = {
    { path = ".hidden", hidden = true },
    { path = "ignored/readme.md", ignored = true },
    { path = "src/main.lua", included = true },
    { path = "src/generated.py", ignored = true },
    { path = "src/private/config.lua", ignored = true },
    { path = "shared-ignored/readme.md", ignored = true },
    { path = "visible.md", included = true },
    { path = "vendor/library.lua", excluded = true },
  },
  ignore_files = { ".gitignore", ".ignore", "src/.gitignore" },
}
