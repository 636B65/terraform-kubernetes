# tflint --recursive --config "$(pwd)/.tflint.hcl" (run by pre-commit and CI)
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}
