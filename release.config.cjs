// safe-d releases are git tags: code.dlang.org picks up each `vX.Y.Z`, and
// the floating `vX` tag moves with it for the reusable workflow. Nothing is
// uploaded anywhere. Pre-1.0: versions stay 0.x (breaking -> minor), and a
// rule that newly fails builds is a minor release (see SAFE-D.md). Cutting
// 1.0.0 is a deliberate config change, not a side effect of a commit message.
module.exports = {
  branches: ['main'],
  plugins: [
    [
      '@semantic-release/commit-analyzer',
      {
        releaseRules: [
          { type: 'feat', release: 'minor' },
          { type: 'fix', release: 'patch' },
          { type: 'perf', release: 'patch' },
          { type: 'revert', release: 'patch' },
          { breaking: true, release: 'minor' },
        ],
      },
    ],
    '@semantic-release/release-notes-generator',
    '@semantic-release/changelog',
    [
      '@semantic-release/exec',
      {
        prepareCmd: 'bash scripts/prepare-release.sh "${nextRelease.version}"',
        successCmd: 'bash scripts/move-major-tag.sh "${nextRelease.version}"',
      },
    ],
    [
      '@semantic-release/git',
      {
        assets: ['CHANGELOG.md', 'check/source/safed/check/version_.d'],
        message:
          'chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}',
      },
    ],
    ['@semantic-release/github', { successComment: false }],
  ],
};
