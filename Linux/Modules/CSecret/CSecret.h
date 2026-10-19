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

// Whether the keyring has a default collection to keep things in. Without one (KWallet
// with no wallet set up, say), Secret Service providers put new items in the session
// collection, which is held in memory and gone at the next login — while reporting that
// the store succeeded.
static inline int csecret_has_default_collection(void) {
    GError *error = NULL;
    SecretService *service = secret_service_get_sync(SECRET_SERVICE_NONE, NULL, &error);
    if (error) g_error_free(error);
    if (!service) return 0;
    error = NULL;
    SecretCollection *collection = secret_collection_for_alias_sync(
        service, SECRET_COLLECTION_DEFAULT, SECRET_COLLECTION_NONE, NULL, &error);
    if (error) g_error_free(error);
    g_object_unref(service);
    if (!collection) return 0;
    g_object_unref(collection);
    return 1;
}
