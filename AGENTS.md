For Debian packaging and kernel compatibility work, use local Bookworm and
Trixie containers as the primary feedback loop. Do not stop after the first
failed patch, compiler error, or manifest failure. Audit complete patch series
and inventories proactively, iterate through successive mechanical blockers,
and run all available builds before returning. Stop only for unresolved
semantic safety questions, unavailable authoritative references, repeated lack
of progress, or unavoidable execution limits. Never commit force-applied
patches or ignored build failures.
