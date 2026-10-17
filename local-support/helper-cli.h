static int local_cli(int argc, char **argv)
{
    if (argc == 1) return -1;
    int restore = argc == 2 && strcmp(argv[1], "--restore-system") == 0;
    int status = argc == 2 && strcmp(argv[1], "--status") == 0;
    if (!restore && !status) return 2;
    if (restore && getuid() != 0) return 2;
    if (smc_open() != kIOReturnSuccess) return 2;
    probe_capabilities();
    int count = 0;
    for (int fan = 0; fan < MAX_FANS; fan++) {
        char key[5]; SMCVal_t value;
        snprintf(key, sizeof(key), "F%dAc", fan);
        if (smc_read_key(key, &value) != kIOReturnSuccess) break;
        count++;
    }
    int ok = count > 0;
    if (restore) {
        for (int fan = 0; fan < count; fan++) {
            if (set_fan_auto(fan) != kIOReturnSuccess) ok = 0;
        }
    }
    printf("{\"restoreRequested\":%s,\"ok\":%s,\"fans\":[", restore ? "true" : "false", ok ? "true" : "false");
    for (int fan = 0; fan < count; fan++) {
        char key[8]; SMCVal_t value; UInt8 mode = 255; int rpm = -1;
        fan_mode_key(fan, key, sizeof(key));
        smc_read_u8(key, &mode);
        snprintf(key, sizeof(key), "F%dAc", fan);
        if (smc_read_key(key, &value) == kIOReturnSuccess) smc_value_to_rpm(&value, &rpm);
        printf("%s{\"index\":%d,\"mode\":%u,\"rpm\":%d}", fan ? "," : "", fan, mode, rpm);
    }
    puts("]}");
    smc_close();
    return ok ? 0 : 1;
}
