#include <libsecret/secret.h>

// A schema is a struct with a fixed C array in it, which Swift can build only clumsily;
// this one is the whole of what the app stores: one string attribute naming the item.
static inline const SecretSchema *csecret_music_schema(void) {
    static const SecretSchema schema = {
        "com.milescoviello.music", SECRET_SCHEMA_NONE,
        {
            { "account", SECRET_SCHEMA_ATTRIBUTE_STRING },
            { NULL, 0 },
        }
    };
    return &schema;
}
