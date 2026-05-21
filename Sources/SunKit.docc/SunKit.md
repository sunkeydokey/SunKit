# ``SunKit``

Core runtime primitives for a Swift server-state library.

## Overview

`SunKit` manages server data lifecycle separately from networking and UI
frameworks. The MVP module is intentionally independent from SwiftUI, UIKit,
Combine, Observation, RxSwift, and networking libraries.

The first supported primitive is query identity through `QueryKey`,
`AnyQueryKey`, and `AnyQueryKeyPart`.
