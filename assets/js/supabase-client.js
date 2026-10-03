import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.2/+esm";

// This publishable browser key is not a secret. Database access must be protected by RLS.
const supabaseUrl = "https://qyedlhdpyupqyzfikkjd.supabase.co";
const publishableKey = "sb_publishable_IgqSaRyB--G1ZMBsdvWyxA_2i7LbTFZ";

export const callbackUrl = "https://nonaschool.com.ua/auth/callback/";
export const supabase = createClient(supabaseUrl, publishableKey, {
  auth: {
    flowType: "pkce",
    detectSessionInUrl: false, // The callback page exchanges the one-time code itself.
    persistSession: true,
    autoRefreshToken: true,
  },
});
