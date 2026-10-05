import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const DAILY_LIMIT = 950;
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return json({ error: "Metodo non consentito." }, 405);

  const authHeader = request.headers.get("Authorization");
  const token = authHeader?.replace(/^Bearer\s+/i, "");
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const omdbKey = Deno.env.get("OMDB_API_KEY");
  if (!token || !supabaseUrl || !anonKey || !serviceKey || !omdbKey) {
    return json({ error: "Servizio non configurato o sessione scaduta." }, 401);
  }

  const authClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await authClient.auth.getUser(token);
  if (authError || !authData.user) return json({ error: "Accedi per cercare film." }, 401);

  const db = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  try {
    const body = await request.json();
    if (body?.action === "search") {
      const query = String(body.query ?? "").trim().replace(/\s+/g, " ");
      if (query.length < 3 || query.length > 100) return json({ results: [] });
      const cacheKey = `search:${query.toLocaleLowerCase()}`;
      const cached = await readCache(db, cacheKey, 30);
      if (cached) return json({ results: cached.Search ?? [] });

      if (!await reserveCall(db)) return json({ error: "Limite giornaliero di ricerca raggiunto. Riprova domani." }, 429);
      const url = new URL("https://www.omdbapi.com/");
      url.searchParams.set("apikey", omdbKey);
      url.searchParams.set("s", query);
      url.searchParams.set("type", "movie");
      url.searchParams.set("page", "1");
      const response = await fetch(url);
      if (!response.ok) throw new Error("OMDb non disponibile.");
      const payload = await response.json();
      if (payload.Response === "False") {
        await writeCache(db, cacheKey, { Search: [] });
        return json({ results: [] });
      }
      const results = (payload.Search ?? []).map((movie: Record<string, string>) => ({
        Title: movie.Title, Year: movie.Year, imdbID: movie.imdbID,
        Type: movie.Type, Poster: movie.Poster,
      }));
      await writeCache(db, cacheKey, { Search: results });
      return json({ results });
    }

    if (body?.action === "details") {
      const drawnFilmId = String(body.drawnFilmId ?? "");
      if (!/^[0-9a-f-]{36}$/i.test(drawnFilmId)) return json({ error: "Film non valido." }, 400);
      const { data: profile, error: profileError } = await db.from("profiles")
        .select("role").eq("id", authData.user.id).maybeSingle();
      if (profileError || profile?.role !== "admin") return json({ error: "Operazione riservata all’admin." }, 403);

      const { data: drawn, error: drawnError } = await db.from("drawn_films")
        .select("id,title,nomination_id").eq("id", drawnFilmId).maybeSingle();
      if (drawnError || !drawn) return json({ error: "Film estratto non trovato." }, 404);
      const { data: nomination, error: nominationError } = await db.from("movie_nominations")
        .select("omdb_id,title").eq("id", drawn.nomination_id).maybeSingle();
      if (nominationError || !nomination) return json({ error: "Nomination non trovata." }, 404);

      const imdbId = String(nomination.omdb_id ?? "").trim();
      const cacheKey = imdbId ? `detail:${imdbId.toLowerCase()}` : `detail-title:${normalize(nomination.title)}`;
      let details = await readCache(db, cacheKey, 180);
      if (!details) {
        if (!await reserveCall(db)) return json({ error: "Limite giornaliero OMDb raggiunto; i dettagli saranno disponibili domani." }, 429);
        const url = new URL("https://www.omdbapi.com/");
        url.searchParams.set("apikey", omdbKey);
        if (imdbId) url.searchParams.set("i", imdbId);
        else url.searchParams.set("t", nomination.title);
        url.searchParams.set("plot", "short");
        const response = await fetch(url);
        if (!response.ok) throw new Error("OMDb non disponibile.");
        details = await response.json();
        await writeCache(db, cacheKey, details);
      }
      const found = details.Response !== "False";
      const metadata = {
        drawn_film_id: drawnFilmId,
        found,
        imdb_id: found ? ((details.imdbID ?? imdbId) || null) : (imdbId || null),
        title: found ? details.Title ?? drawn.title : drawn.title,
        year: found ? details.Year ?? null : null,
        rated: found ? details.Rated ?? null : null,
        released: found ? details.Released ?? null : null,
        runtime: found ? details.Runtime ?? null : null,
        genre: found ? details.Genre ?? null : null,
        director: found ? details.Director ?? null : null,
        actors: found ? details.Actors ?? null : null,
        plot: found ? details.Plot ?? null : null,
        language: found ? details.Language ?? null : null,
        country: found ? details.Country ?? null : null,
        awards: found ? details.Awards ?? null : null,
        poster_url: found && details.Poster !== "N/A" ? details.Poster ?? null : null,
        imdb_rating: found && details.imdbRating !== "N/A" ? details.imdbRating ?? null : null,
        imdb_votes: found && details.imdbVotes !== "N/A" ? details.imdbVotes ?? null : null,
        metascore: found && details.Metascore !== "N/A" ? details.Metascore ?? null : null,
        updated_at: new Date().toISOString(),
      };
      const { error: saveError } = await db.from("drawn_film_metadata").upsert(metadata);
      if (saveError) throw saveError;
      return json({ metadata });
    }

    return json({ error: "Azione non valida." }, 400);
  } catch (error) {
    console.error("OMDb function error", error);
    return json({ error: "Impossibile recuperare i dati del film." }, 500);
  }
});

async function readCache(db: ReturnType<typeof createClient>, key: string, ttlDays: number) {
  const { data, error } = await db.from("omdb_cache").select("payload,fetched_at").eq("cache_key", key).maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const age = Date.now() - new Date(data.fetched_at).getTime();
  return age <= ttlDays * 86400_000 ? data.payload : null;
}

async function writeCache(db: ReturnType<typeof createClient>, key: string, payload: unknown) {
  const { error } = await db.from("omdb_cache").upsert({ cache_key: key, payload, fetched_at: new Date().toISOString() });
  if (error) console.error("OMDb cache write failed", error.message);
}

async function reserveCall(db: ReturnType<typeof createClient>) {
  const { data, error } = await db.rpc("reserve_omdb_api_call", { p_daily_limit: DAILY_LIMIT });
  if (error) throw error;
  return data === true;
}

function normalize(value: string) {
  return value.toLocaleLowerCase().normalize("NFKD").replace(/[\u0300-\u036f]/g, "").replace(/\s+/g, " ").trim();
}
