# frozen_string_literal: true

require_relative "lib/tallmadge"

Gem::Specification.new do |spec|
  spec.name          = "tallmadge"
  spec.version       = Tallmadge::VERSION
  spec.authors       = ["Kevin Lawver"]
  spec.summary       = "CLI manager for ~/.agents/ and AI coding harness extensions"
  spec.homepage      = "https://github.com/kplawver/tallmadge"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files         = Dir["lib/**/*.rb", "bin/*", "README.md", "LICENSE*"]
  spec.bindir        = "bin"
  spec.executables   = ["clpr"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rainbow", "~> 3.1"
  spec.add_dependency "thor", "~> 1.5"
end
