#!/usr/bin/env python3
"""Fail before building if release credentials are incomplete. Never print secret values."""
import os
from configure_bundle import update_configuration
required = ['CERTIFICATE_P12_BASE64', 'CERTIFICATE_PASSWORD', 'LUMARING_SIGN_IDENTITY',
            'APPLE_API_KEY_P8', 'APPLE_API_KEY_ID', 'APPLE_API_ISSUER', 'SPARKLE_PRIVATE_KEY']
missing = [name for name in required if not os.environ.get(name)]
if missing:
    raise SystemExit('Missing release secrets: ' + ', '.join(missing))
if not os.environ['LUMARING_SIGN_IDENTITY'].startswith('Developer ID Application:'):
    raise SystemExit('A Developer ID Application identity is required for distribution.')
if os.environ.get('GITHUB_REPOSITORY') != update_configuration()['repository']:
    raise SystemExit('Release repository does not match the embedded update feed. Configure forks explicitly.')
