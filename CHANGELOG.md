# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

### Changed
- Improved exception handling for better reliability during API calls.

### Fixed
- Fixed dependency resolution error caused by mismatched project name.
- Resolved issues with socket connection stability.

## [1.0.0+1] - 2024-08-25
### Added
- Initial release of `router_os_client`.
- Basic API connection functionality for RouterOS devices.
- Added documentation and examples for usage.

## [1.0.0+2] - 2024-08-27
### Changed
- Reformated `router_os_client` file.


## [1.0.0+3] - 2024-08-27
### Removed
- Removed cupertino_icons from dependencies.

## [1.0.2] - 2024-08-31
### Fix
- fix: prevent empty maps from being added to parsed replies

- Modified the `_parseReply` method to ensure that only non-empty maps are added to the `parsedReplies` list. This prevents the unnecessary `{}` from being returned at the end of command execution.

