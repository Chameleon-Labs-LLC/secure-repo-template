# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.1] - 2026-11-09

### Changed
- Address CodeRabbit review on #1
- Download scanners outside the checkout; scan pyproject.toml dependencies
- Close the gaps found in review: suppression symlinks, npm coverage, installer ownership
- Move hooks to Scripts/githooks to match the published setup guide
- Add the security setup: hooks, CI scans, Dependabot, reviewer configs, docs
- Initial commit: MIT license and README stub
