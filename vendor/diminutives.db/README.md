# diminutives.db

`male_diminutives.csv` and `female_diminutives.csv` are copied unmodified from
<https://github.com/HaJongler/diminutives.db> at commit
`caae757f1f91bce2175a49942a6c466846ade50c`, a fork of
<https://github.com/dtrebbien/diminutives.db>.

Upstream publishes the two CSV files as **Public Domain**. Its scripts are
GPL-3; none are copied here.

Each line is a formal given name followed by its common English diminutives:

    Nathaniel,Nat,Nate

`app/lib/name_variants.rb` reads these files. What Atlas does with them, and
why, is in [`docs/solr-indexing.md`](../../docs/solr-indexing.md#namevariantindexer).

Keep the files byte-identical to upstream, so a later refresh is a plain copy.
Filter a row out in `NameVariants` rather than editing it here.
