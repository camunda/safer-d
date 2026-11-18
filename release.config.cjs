// safe-d releases are git tags: code.dlang.org picks up each `vX.Y.Z`, and
// the floating `vX` tag moves with it for the reusable workflow. Nothing is
// uploaded anywhere. A breaking change (to the library API, safe-d.json or
// the CLI) is a major release. A new rule is not: it ships as `warn` in a
// minor and becomes an error one minor later (see SAFE-D.md).
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
