#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nesturbator.h"

#ifndef LIBFUTURO_NESTURBATOR_SOURCE_REVISION
#define LIBFUTURO_NESTURBATOR_SOURCE_REVISION "unverified"
#endif

#define EXPECTED_NESTURBATOR_SOURCE_REVISION "2338608ab184f040620a30d17756f5e06a42d4e3"

int main(void) {
    if (strcmp(LIBFUTURO_NESTURBATOR_SOURCE_REVISION,
               EXPECTED_NESTURBATOR_SOURCE_REVISION) != 0) {
        fprintf(stderr,
                "nesturbator_probe: source_revision_mismatch expected=%s actual=%s\n",
                EXPECTED_NESTURBATOR_SOURCE_REVISION,
                LIBFUTURO_NESTURBATOR_SOURCE_REVISION);
        return EXIT_FAILURE;
    }

    nesturbator_config config;
    memset(&config, 0, sizeof(config));
    config.size = (uint32_t)sizeof(config);
    config.abi = NESTURBATOR_ABI_VERSION;

    nesturbator *instance = NULL;
    nesturbator_status status = nesturbator_create(&config, &instance);
    if (status != NESTURBATOR_OK) {
        fprintf(stderr, "nesturbator_probe: create failed with status %u\n",
                (unsigned)status);
        return EXIT_FAILURE;
    }
    if (instance == NULL) {
        fputs("nesturbator_probe: create succeeded without an instance\n", stderr);
        return EXIT_FAILURE;
    }

    nesturbator_destroy(instance);
    printf("nesturbator_probe: source=%s lifecycle=create,destroy result=pass\n",
           LIBFUTURO_NESTURBATOR_SOURCE_REVISION);
    return EXIT_SUCCESS;
}
