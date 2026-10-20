-- Editor-only performance settings. Runtime gameplay does not read this file.
return {
    -- Batch changed existing resources on Windows using the shipped PowerShell
    -- helper. Disable to use ordinary compare-before-write for diagnosis.
    batch_existing_writes = true,
    -- Smaller batches use ordinary writes to avoid process startup overhead.
    existing_write_threshold = 8,
    -- Rotate the editor debug log at session start; preserve one .1 backup.
    -- Set to 0 to disable rotation. This is a byte limit (5 MiB by default).
    debug_log_max_bytes = 5 * 1024 * 1024,
}
