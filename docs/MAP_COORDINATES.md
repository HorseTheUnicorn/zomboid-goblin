# Map coordinates

Exact `x/y/z` values are tracker telemetry. They may be stored for the live
map and Goblin history, but are not copied into `brain_view`, Qwen prompts,
model output, events, or semantic command labels. Numeric distance values are
also treated as a location side channel; coarse values such as `near`, `far`,
and `distance_bucket` remain available to cognition.
