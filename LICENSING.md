# Licensing

Copyright 2026 Sturgeon Technologies LLC. "RC Race HQ" and its logo are
trademarks of Sturgeon Technologies LLC.

This is **source-available**, not open source (yet). In plain terms:

| You can | You can't |
|---|---|
| Build, install and run the lap counter at your own club or track | Sell it, or a modified copy, as your own product |
| Read, modify and fix the code, and share your changes | Offer it as a paid service that competes with RC Race HQ |
| Use it for education or research | Call your build "RC Race HQ" or "official" |
| Help a club set it up as paid professional services | Remove the copyright or license notices |

The lap counter is built to work with an RC Race HQ account (pairing, event
sync, uploads and the transponder library).

## Which license covers what

- **Software** (install script, helper files, docs): [Functional Source License 1.1,
  Apache 2.0 Future License](LICENSE) (`FSL-1.1-ALv2`). Each version becomes
  Apache-2.0 two years after it is released.
- **OpenStint** (the RF decoder the Pi runs) is a separate program by its own
  authors under GPL-3.0. We install it from upstream and talk to it over its
  protocol; none of its code is in this repo.

This summary is for convenience. The license files are what apply.
