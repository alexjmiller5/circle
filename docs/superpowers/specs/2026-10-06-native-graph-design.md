# Native graph milestone

Approved design: the three-layout explorer. SwiftUI on iOS and macOS, with no web view.

- The explorer shall offer Constellation, Pathways and Orbits while preserving selected people/groups.
- First launch shall use Constellation, Circles, and boundaries off. Validated display preferences shall persist locally.
- Re-selecting the current focus or using Back to me shall recenter after a pan, even when selection has not changed.
- When a person or group is selected, the camera shall center that selection. Back restores the previous selection and modes; Back to me centers the configured self identity.
- Constellation shall group by recorded connections, circles or city. City shall distinguish base from current presence and show Unknown explicitly.
- Pathways shall retain recorded introducer direction when focus changes. Circle membership shall not invent friendship edges.
- Orbits shall show graph distance from the selected person and retain that reference while focusing a group. Disconnected people remain visible separately.
- The explorer shall support search, pan, zoom, node drag, optional soft boundaries and reduced motion, with accessible controls on narrow phones and Mac windows.
- Multi-circle membership remains available in groups; a node is drawn once. Missing facts are not fabricated.
- Layout work shall handle 1,500 synthetic people without all-pairs force settling on each frame.
- Development data shall be explicitly labeled and isolated from normal launch. No personal records, credentials, contact exports or raw task snapshots enter git.

This milestone provides a native, fixture-verifiable presentation. Supported narrow service enrollment, authenticated photos and live data are a separate integration dependency. Normal launch shows an honest unconnected state. Notifications, tracking-preference scope and alert policy are not decided here.
