import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY } from "./supabase-config.js";

const configured = SUPABASE_URL.startsWith("https://")
  && !SUPABASE_URL.includes("YOUR-PROJECT")
  && SUPABASE_PUBLISHABLE_KEY.length > 20
  && !SUPABASE_PUBLISHABLE_KEY.includes("YOUR_SUPABASE");
const supabase = configured ? createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY) : null;

const authScreen = document.querySelector("#auth-screen");
const appScreen = document.querySelector("#app-screen");
const authForm = document.querySelector("#auth-form");
const authSubmit = document.querySelector("#auth-submit");
const authSwitch = document.querySelector("#auth-switch");
const authSwitchCopy = document.querySelector("#auth-switch-copy");
const authTitle = document.querySelector("#auth-title");
const authSubtitle = document.querySelector("#auth-subtitle");
const authEyebrow = document.querySelector("#auth-eyebrow");
const usernameField = document.querySelector("#username-field");
const configNotice = document.querySelector("#config-notice");
const nightView = document.querySelector("#night-view");
const leaderboardView = document.querySelector("#leaderboard-view");
const leaderboardTab = document.querySelector("#leaderboard-tab");
const leaderboardLock = document.querySelector("#leaderboard-lock");
const toastRegion = document.querySelector("#toast-region");

let authMode = "login";
let currentUser = null;
let currentProfile = null;
let dashboard = null;
let activeTab = "night";
let loading = false;

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (char) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[char]);
}

function toast(message, kind = "") {
  const item = document.createElement("div");
  item.className = "toast " + kind;
  item.textContent = message;
  toastRegion.append(item);
  window.setTimeout(() => item.remove(), 4300);
}

function readableError(error) {
  const message = error?.message || "Si è verificato un errore. Riprova.";
  if (/duplicate key|unique constraint/i.test(message)) return "Questo film è già stato proposto nella serata.";
  if (/username riservato/i.test(message)) return "Questo username è riservato all'admin.";
  if (/invalid login credentials/i.test(message)) return "Email o password non corretti.";
  if (/email not confirmed/i.test(message)) return "Conferma prima l'indirizzo email dal messaggio ricevuto.";
  return message;
}

function setAuthMode(mode) {
  authMode = mode;
  const signup = mode === "signup";
  usernameField.hidden = !signup;
  document.querySelector("#username-input").required = signup;
  document.querySelector("#password-input").autocomplete = signup ? "new-password" : "current-password";
  authEyebrow.textContent = signup ? "ENTRA NEL CLUB" : "BENVENUTO NEL CLUB";
  authTitle.textContent = signup ? "Crea il tuo account" : "Accedi alla serata";
  authSubtitle.textContent = signup
    ? "Scegli uno username e registrati con la tua email."
    : "Entra con l'email e la password del tuo account.";
  authSubmit.innerHTML = signup ? 'Crea account <span aria-hidden="true">→</span>' : 'Accedi <span aria-hidden="true">→</span>';
  authSwitchCopy.textContent = signup ? "Hai già un account?" : "Non hai ancora un account?";
  authSwitch.textContent = signup ? "Accedi" : "Registrati";
}

function showAuth() {
  currentUser = null;
  currentProfile = null;
  dashboard = null;
  appScreen.hidden = true;
  authScreen.hidden = false;
  configNotice.hidden = configured;
  authSubmit.disabled = !configured;
  setAuthMode("login");
}

async function enterApp(user) {
  currentUser = user;
  authScreen.hidden = true;
  appScreen.hidden = false;
  nightView.innerHTML = '<div class="loading"><span class="spinner"></span> Apro la serata…</div>';
  try {
    const { data: profile, error } = await supabase
      .from("profiles").select("id,username,role").eq("id", user.id).maybeSingle();
    if (error) throw error;
    if (!profile) throw new Error("Profilo non trovato. Prova a uscire e accedere di nuovo.");
    currentProfile = profile;
    document.querySelector("#topbar-user").textContent = profile.username;
    document.querySelector("#welcome-title").innerHTML = "Ciao, " + escapeHtml(profile.username) + ' <span>✦</span>';
    await refreshDashboard();
  } catch (error) {
    toast(readableError(error), "error");
    showAuth();
  }
}

async function refreshDashboard(quiet = false) {
  if (!currentUser || loading) return;
  loading = true;
  try {
    const { data: night, error: nightError } = await supabase
      .from("movie_nights").select("id,title,phase,revealed_count,created_at,finished_at")
      .order("created_at", { ascending: false }).limit(1).maybeSingle();
    if (nightError) throw nightError;
    if (!night) {
      dashboard = { night: null, isMember: false, members: [], draws: [], categories: {},
        myNomination: null, mySeen: {}, myRatings: {}, assignment: null, leaderboard: null, revealed: [] };
      renderAll();
      return;
    }

    const { data: memberRows, error: memberError } = await supabase
      .from("night_members").select("night_id,user_id,has_nominated,joined_at")
      .eq("night_id", night.id).order("joined_at", { ascending: true });
    if (memberError) throw memberError;
    const members = memberRows || [];
    const isMember = members.some((member) => member.user_id === currentUser.id);
    const memberIds = members.map((member) => member.user_id);
    let profileRows = [];
    if (memberIds.length) {
      const { data, error } = await supabase.from("profiles").select("id,username,role").in("id", memberIds);
      if (error) throw error;
      profileRows = data || [];
    }
    const profileMap = Object.fromEntries(profileRows.map((profile) => [profile.id, profile]));
    const { data: categoryRows, error: categoryError } = await supabase
      .from("film_categories").select("id,name");
    if (categoryError) throw categoryError;
    const categories = Object.fromEntries((categoryRows || []).map((category) => [category.id, category.name]));

    const { data: drawRows, error: drawError } = await supabase
      .from("drawn_films").select("id,title,category_id,status,member_count,rating_count,seen_count,drawn_at,decided_at")
      .eq("night_id", night.id).order("drawn_at", { ascending: true });
    if (drawError) throw drawError;
    const draws = drawRows || [];
    let myNomination = null;
    let assignment = null;
    let leaderboard = null;
    let revealed = [];
    const mySeen = {};
    const myRatings = {};

    if (isMember) {
      const { data: assignmentRows, error: assignmentError } = await supabase.rpc("get_my_assignment", { p_night_id: night.id });
      if (assignmentError) throw assignmentError;
      assignment = assignmentRows?.[0] || null;
      const { data: nomination, error: nominationError } = await supabase
        .from("movie_nominations").select("title,status").eq("night_id", night.id).eq("user_id", currentUser.id).maybeSingle();
      if (nominationError) throw nominationError;
      myNomination = nomination;

      const drawIds = draws.map((draw) => draw.id);
      if (drawIds.length) {
        const [{ data: seenRows, error: seenError }, { data: ratingRows, error: ratingError }] = await Promise.all([
          supabase.from("seen_votes").select("drawn_film_id,has_seen").eq("user_id", currentUser.id).in("drawn_film_id", drawIds),
          supabase.from("movie_ratings").select("drawn_film_id,rating").eq("user_id", currentUser.id).in("drawn_film_id", drawIds),
        ]);
        if (seenError) throw seenError;
        if (ratingError) throw ratingError;
        for (const row of seenRows || []) mySeen[row.drawn_film_id] = row.has_seen;
        for (const row of ratingRows || []) myRatings[row.drawn_film_id] = Number(row.rating);
      }
      const { data: stateRows, error: stateError } = await supabase.rpc("get_leaderboard_state", { p_night_id: night.id });
      if (stateError) throw stateError;
      leaderboard = stateRows?.[0] || null;
      if (leaderboard?.unlocked) {
        const { data: revealedRows, error: revealedError } = await supabase.rpc("get_revealed_movies", { p_night_id: night.id });
        if (revealedError) throw revealedError;
        revealed = revealedRows || [];
      }
    }

    dashboard = { night, isMember, members, profileMap, draws, categories, myNomination,
      mySeen, myRatings, assignment, leaderboard, revealed };
    renderAll();
  } catch (error) {
    if (!quiet) toast(readableError(error), "error");
    if (!dashboard) nightView.innerHTML = '<div class="error-box">' + escapeHtml(readableError(error)) + "</div>";
  } finally {
    loading = false;
  }
}

function renderEmpty(title, description, action = "") {
  return '<div class="empty-state"><div><div class="empty-icon">✦</div><h2>'
    + escapeHtml(title) + "</h2><p>" + escapeHtml(description) + "</p>" + action + "</div></div>";
}

function renderAdminPanel(night, allNominated, poolRemaining, canDraw) {
  if (currentProfile?.role !== "admin") return "";
  if (!night) {
    return '<article class="card admin-card"><h3>Controlli admin</h3><p>Avvia una serata: verrà assegnata una categoria casuale a ogni account già registrato.</p><button class="button button-primary" data-action="start-night">Assegna le categorie</button></article>';
  }
  if (night.phase === "complete") {
    return '<article class="card admin-card"><h3>Serata conclusa</h3><p>La classifica è stata rivelata. Puoi aprire una nuova serata e assegnare altre categorie.</p><button class="button button-primary" data-action="start-night">Nuova serata</button></article>';
  }
  let explanation = "";
  if (!allNominated) explanation = "Aspetta che tutti i partecipanti inviino la propria nomination.";
  else if (poolRemaining === 0) explanation = "Pool esaurito. Completa i voti rimasti per sbloccare la classifica.";
  else if (!canDraw) explanation = "Completa la verifica e le valutazioni del film attuale prima della prossima estrazione.";
  else explanation = poolRemaining + (poolRemaining === 1 ? " film nel pool, pronto per il sorteggio." : " film nel pool, pronti per il sorteggio.");
  const buttonText = dashboard?.draws.length ? "Pesca il prossimo film" : "Sorteggia un film";
  return '<article class="card admin-card"><div class="admin-row"><div><h3>Controlli admin</h3><p>' + escapeHtml(explanation)
    + '</p></div><span class="pool-label">Pool · ' + poolRemaining + '</span></div><button class="button button-primary" data-action="draw-film" '
    + (canDraw ? "" : "disabled") + ">" + buttonText + ' <span aria-hidden="true">↗</span></button></article>';
}

function renderMemberRows(members, profileMap) {
  if (!members.length) return '<p class="small-muted">Nessun partecipante trovato.</p>';
  return '<div class="member-list">' + members.map((member) => {
    const person = profileMap?.[member.user_id] || { username: "utente", role: "player" };
    const isSelf = member.user_id === currentUser.id;
    const state = member.has_nominated
      ? '<span class="member-state done">✓ Nomination inserita</span>'
      : '<span class="member-state">In attesa</span>';
    const role = person.role === "admin" ? '<span class="member-state admin">Admin</span>' : "";
    return '<div class="member-row"><div class="member-name"><span class="avatar">'
      + escapeHtml(person.username.slice(0, 2)) + '</span><span>' + escapeHtml(person.username)
      + (isSelf ? " (tu)" : "") + "</span></div><div>" + role + state + "</div></div>";
  }).join("") + "</div>";
}

function ratingLabel(value) {
  const whole = Math.floor(value);
  return value % 1 ? whole + "½" : String(whole);
}

function renderDrawCard(draw, index, categories, mySeen, myRatings, phase) {
  const category = categories[draw.category_id] || "Cinema";
  let stateHtml = "";
  if (draw.status === "checking") {
    const ownVote = mySeen[draw.id];
    stateHtml = '<div class="vote-prompt"><strong>Lo hai già visto?</strong><p>Il risultato resta segreto finché tutti non hanno risposto. Il film viene sostituito se almeno il 60% lo ha già visto.</p>'
      + (ownVote === undefined ? "" : '<p class="film-status waiting">La tua risposta è registrata. Puoi cambiarla fino alla chiusura del voto.</p>')
      + '<div class="seen-actions"><button class="button ' + (ownVote === true ? "button-danger" : "button-quiet")
      + '" data-action="seen-vote" data-id="' + draw.id + '" data-value="true">L’ho visto</button><button class="button '
      + (ownVote === false ? "button-secondary" : "button-quiet") + '" data-action="seen-vote" data-id="' + draw.id
      + '" data-value="false">Non l’ho visto</button></div></div>';
  } else if (draw.status === "rejected") {
    stateHtml = '<div class="film-status warning">Film sostituito · ' + draw.seen_count + "/" + draw.member_count
      + " persone lo avevano già visto. Il titolo non rientra nel pool.</div>";
  } else {
    const rating = myRatings[draw.id];
    const canEdit = phase === "nominations";
    const options = [1, 1.5, 2, 2.5, 3, 3.5, 4, 4.5, 5];
    stateHtml = '<div class="film-status success">Film approvato · ' + draw.seen_count + "/" + draw.member_count
      + ' persone lo avevano già visto.</div><div class="vote-prompt"><strong>'
      + (rating === undefined ? "Quanto ti è piaciuto?" : "Il tuo voto: " + ratingLabel(rating) + " popcorn")
      + "</strong><p>" + draw.rating_count + "/" + draw.member_count + " voti ricevuti"
      + (canEdit && rating !== undefined ? " · puoi modificare il tuo voto" : "") + "</p>"
      + (canEdit ? '<div class="rating-options">' + options.map((value) =>
        '<button class="rating-option ' + (rating === value ? "selected" : "") + '" data-action="rate-film" data-id="'
        + draw.id + '" data-value="' + value + '" aria-label="' + ratingLabel(value) + ' popcorn"><span class="pop">🍿</span>'
        + ratingLabel(value) + "</button>").join("") + "</div>" : "") + "</div>";
  }
  return '<article class="film-card"><div><h3 class="film-title">' + escapeHtml(draw.title) + '</h3><div class="film-meta">'
    + escapeHtml(category) + " · estratto " + (index + 1) + "</div>" + stateHtml
    + '</div><span class="film-num">' + String(index + 1).padStart(2, "0") + "</span></article>";
}

function renderNight() {
  if (!dashboard?.night) {
    nightView.innerHTML = currentProfile?.role === "admin"
      ? '<div class="section-heading"><div><span class="section-kicker">PRONTI A COMINCIARE?</span><h2>La prossima serata inizia qui</h2><p>Registra gli amici, poi assegna a ciascuno una categoria casuale.</p></div></div>'
        + renderEmpty("Nessuna serata attiva", "Quando avvii una serata, tutti gli account registrati ricevono una categoria.")
        + '<div class="admin-control">' + renderAdminPanel(null, false, 0, false) + "</div>"
      : renderEmpty("Ancora nessuna serata", "L’admin deve avviare la serata e assegnare le categorie ai partecipanti.");
    return;
  }

  const { night, members, profileMap, draws, categories, isMember, assignment, myNomination, mySeen, myRatings, leaderboard } = dashboard;
  if (!isMember) {
    nightView.innerHTML = renderEmpty("Non sei in questa serata", "Questa serata è stata aperta prima della tua registrazione. Potrai partecipare alla prossima.")
      + (currentProfile?.role === "admin" ? '<div class="admin-control">' + renderAdminPanel(night, false, 0, false) + "</div>" : "");
    return;
  }
  const memberCount = members.length;
  const submittedCount = members.filter((member) => member.has_nominated).length;
  const allNominated = memberCount > 0 && submittedCount === memberCount;
  const poolRemaining = Math.max(0, submittedCount - draws.length);
  const hasChecking = draws.some((draw) => draw.status === "checking");
  const waitingRatings = draws.some((draw) => draw.status === "approved" && draw.rating_count < draw.member_count);
  const canDraw = night.phase === "nominations" && allNominated && poolRemaining > 0 && !hasChecking && !waitingRatings;
  const phaseLabel = night.phase === "complete" ? "Serata conclusa" : leaderboard?.unlocked ? "Classifica da rivelare" : "Serata in corso";
  const phaseClass = night.phase === "complete" ? "success" : "";
  const categoryName = assignment?.category_name || "Categoria assegnata";
  const nominationBox = myNomination
    ? '<div class="your-nomination"><span aria-hidden="true">✓</span> Nomination inviata: <strong>' + escapeHtml(myNomination.title) + "</strong></div>"
    : '<form id="nomination-form" class="nomination-form"><label for="movie-title">Scegli il tuo film</label><input id="movie-title" name="title" maxlength="140" required placeholder="Titolo del film…"><button class="button button-primary" type="submit">Invia nomination <span aria-hidden="true">→</span></button></form>';
  const drawSection = draws.length
    ? '<div class="divider"></div><div class="section-heading"><div><span class="section-kicker">POOL ESTRATTO</span><h2>Film della serata</h2><p>Vengono mostrati solo dopo il sorteggio.</p></div></div><div class="film-list">'
      + draws.map((draw, i) => renderDrawCard(draw, i, categories, mySeen, myRatings, night.phase)).join("") + "</div>"
    : '<div class="divider"></div><p class="small-muted">I titoli restano segreti fino al sorteggio. Per ora puoi vedere solo chi ha completato la nomination.</p>';
  const unlockedText = leaderboard?.unlocked
    ? '<span class="status-chip success">Classifica sbloccata</span>'
    : '<span class="status-chip">' + (allNominated ? "In attesa delle estrazioni e dei voti" : submittedCount + "/" + memberCount + " nomination") + "</span>";

  nightView.innerHTML = '<div class="night-banner"><div><span class="eyebrow">SERATA CINEMA · '
    + escapeHtml(new Date(night.created_at).toLocaleDateString("it-IT", { day: "numeric", month: "long" }))
    + '</span><h2>' + escapeHtml(night.title || "Serata cinema") + '</h2><p>Una categoria, una nomination e un film scelto dal caso.</p></div><span class="status-chip '
    + phaseClass + '">' + escapeHtml(phaseLabel) + '</span></div><div class="stats-grid">'
    + '<article class="stat-card"><div class="stat-label">PARTECIPANTI</div><div class="stat-value">' + memberCount + '<small>persone</small></div></article>'
    + '<article class="stat-card"><div class="stat-label">NOMINATION</div><div class="stat-value">' + submittedCount + '<small>su ' + memberCount + '</small></div></article>'
    + '<article class="stat-card"><div class="stat-label">POOL RIMASTO</div><div class="stat-value">' + poolRemaining + '<small>film</small></div></article></div>'
    + '<div class="content-grid"><div class="main-column"><article class="card assignment-card"><span class="assignment-icon" aria-hidden="true">✦</span><span class="eyebrow">LA TUA CATEGORIA</span><h3>'
    + escapeHtml(categoryName) + '</h3><p>Nomina un film che appartenga a questa categoria. Gli altri vedranno che hai partecipato, non il titolo.</p>'
    + nominationBox + "</article>" + drawSection + '</div><aside class="side-column">'
    + '<article class="card card-pad"><div class="section-heading"><div><span class="section-kicker">GLI AMICI</span><h2>Partecipanti</h2></div><span class="status-chip">'
    + submittedCount + "/" + memberCount + "</span></div>" + renderMemberRows(members, profileMap) + "</article>"
    + '<article class="card card-pad"><div class="section-heading"><div><span class="section-kicker">CLASSIFICA</span><h2>Premiazione</h2></div></div><p class="small-muted">'
    + (leaderboard?.unlocked ? "Il pool è terminato. L’admin può rivelare le posizioni una alla volta." : "Si sblocca quando il pool è vuoto e tutti i film approvati hanno ricevuto un voto.")
    + "</p>" + unlockedText + "</article><div class=\"admin-control\">"
    + renderAdminPanel(night, allNominated, poolRemaining, canDraw) + "</div></aside></div>";
}

function podiumLabel(position) {
  if (position === 1) return "🥇 PRIMO POSTO";
  if (position === 2) return "🥈 SECONDO POSTO";
  if (position === 3) return "🥉 TERZO POSTO";
  return "";
}

function renderLeaderboard() {
  if (!dashboard?.night || !dashboard.isMember) {
    leaderboardView.innerHTML = renderEmpty("Classifica non disponibile", "Partecipa a una serata attiva per vedere la premiazione.");
    return;
  }
  const state = dashboard.leaderboard;
  if (!state?.unlocked) {
    leaderboardView.innerHTML = renderEmpty("La classifica è ancora segreta", "Quando tutte le nomination saranno estratte e votate, l’admin potrà rivelare le posizioni una alla volta.");
    return;
  }
  if (state.total_films === 0) {
    leaderboardView.innerHTML = '<div class="leaderboard-header"><div><span class="eyebrow">PREMIAZIONE</span><h2>Nessun film in classifica</h2><p>Tutti i titoli estratti sono stati sostituiti durante la verifica.</p></div></div>';
    return;
  }
  const remaining = Math.max(0, state.total_films - state.revealed);
  let adminReveal = "";
  if (currentProfile?.role === "admin" && remaining > 0) {
    adminReveal = '<button class="button button-primary" data-action="reveal-rank">Rivela la prossima posizione <span aria-hidden="true">↗</span></button>';
  } else if (currentProfile?.role === "admin") {
    adminReveal = '<span class="status-chip success">Classifica completa</span>';
  } else if (remaining > 0) {
    adminReveal = '<span class="small-muted">L’admin sta rivelando la prossima posizione.</span>';
  } else {
    adminReveal = '<span class="status-chip success">Classifica completa</span>';
  }
  const cards = (dashboard.revealed || []).map((movie) => {
    const podium = podiumLabel(movie.position);
    return '<article class="rank-card ' + (movie.position <= 3 ? "rank-top" : "") + '"><div class="rank-position">'
      + movie.position + '</div><div><h3 class="rank-title">' + escapeHtml(movie.title)
      + (podium ? '<span class="podium-label">' + podium + "</span>" : "") + '</h3><div class="rank-meta">'
      + escapeHtml(movie.category_name) + " · " + movie.vote_count + " voti</div></div><div class=\"rank-score\">"
      + Number(movie.average_rating).toFixed(2) + "<small>🍿 media</small></div></article>";
  }).join("");
  leaderboardView.innerHTML = '<div class="leaderboard-header"><div><span class="eyebrow">LA PREMIAZIONE</span><h2>Dal fondo al podio</h2><p>Ogni rivelazione mostra una posizione, dalla meno votata alla più amata.</p></div><div class="reveal-progress">'
    + state.revealed + " di " + state.total_films + ' rivelate<div class="admin-control" style="margin-top:10px">'
    + adminReveal + "</div></div></div>"
    + (remaining ? '<div class="card card-pad" style="margin-bottom:14px"><div class="small-muted">' + remaining
      + (remaining === 1 ? " posizione da rivelare" : " posizioni da rivelare")
      + (currentProfile?.role === "admin" ? " · premi il pulsante per continuare" : " · attendi il prossimo reveal dell’admin")
      + "</div></div>" : "")
    + '<div class="reveal-list">' + (cards || '<div class="empty-state"><div><div class="empty-icon">🎞</div><h2>La prima posizione è ancora coperta</h2><p>L’admin può rivelare la classifica dalla posizione più bassa.</p></div></div>') + "</div>";
}

function renderAll() {
  renderNight();
  renderLeaderboard();
  const unlocked = Boolean(dashboard?.leaderboard?.unlocked);
  leaderboardTab.disabled = !unlocked;
  leaderboardLock.hidden = unlocked;
  document.querySelectorAll(".tab[data-tab]").forEach((tab) => tab.classList.toggle("active", tab.dataset.tab === activeTab));
  nightView.hidden = activeTab !== "night";
  leaderboardView.hidden = activeTab !== "leaderboard";
  if (!unlocked && activeTab === "leaderboard") {
    activeTab = "night";
    nightView.hidden = false;
    leaderboardView.hidden = true;
    document.querySelector('.tab[data-tab="night"]').classList.add("active");
  }
}

async function runAction(action, button) {
  if (action !== "start-night" && !dashboard?.night) return;
  if (button?.disabled) return;
  if (button) button.disabled = true;
  try {
    if (action === "start-night") {
      const { error } = await supabase.rpc("start_movie_night");
      if (error) throw error;
      toast("Serata avviata: le categorie sono state assegnate.", "success");
    } else if (action === "draw-film") {
      const { error } = await supabase.rpc("admin_draw_next", { p_night_id: dashboard.night.id });
      if (error) throw error;
      toast("Film estratto. Tutti possono votare se l’hanno già visto.", "success");
    } else if (action === "seen-vote") {
      const { error } = await supabase.rpc("submit_seen_vote", {
        p_drawn_film_id: button.dataset.id,
        p_has_seen: button.dataset.value === "true",
      });
      if (error) throw error;
      toast("Risposta registrata in modo riservato.", "success");
    } else if (action === "rate-film") {
      const { error } = await supabase.rpc("cast_movie_rating", {
        p_drawn_film_id: button.dataset.id,
        p_rating: Number(button.dataset.value),
      });
      if (error) throw error;
      toast("Il tuo voto è stato registrato.", "success");
    } else if (action === "reveal-rank") {
      const { error } = await supabase.rpc("admin_reveal_next_rank", { p_night_id: dashboard.night.id });
      if (error) throw error;
      activeTab = "leaderboard";
      toast("Una nuova posizione è stata rivelata.", "success");
    }
    await refreshDashboard();
  } catch (error) {
    toast(readableError(error), "error");
    await refreshDashboard(true);
  } finally {
    if (button) button.disabled = false;
  }
}

authSwitch.addEventListener("click", () => setAuthMode(authMode === "login" ? "signup" : "login"));
authForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (!configured) return;
  const email = document.querySelector("#email-input").value.trim();
  const password = document.querySelector("#password-input").value;
  const username = document.querySelector("#username-input").value.trim().toLowerCase();
  authSubmit.disabled = true;
  authSubmit.textContent = authMode === "signup" ? "Creo l’account…" : "Accesso…";
  try {
    if (authMode === "signup") {
      const { data, error } = await supabase.auth.signUp({
        email, password, options: { data: { username } },
      });
      if (error) throw error;
      if (data.session) {
        await enterApp(data.user);
      } else {
        toast("Account creato. Se la conferma email è attiva, apri il link che ti abbiamo inviato e poi accedi.", "success");
        setAuthMode("login");
      }
    } else {
      const { data, error } = await supabase.auth.signInWithPassword({ email, password });
      if (error) throw error;
      await enterApp(data.user);
    }
  } catch (error) {
    toast(readableError(error), "error");
  } finally {
    authSubmit.disabled = !configured;
    setAuthMode(authMode);
  }
});

document.querySelector("#sign-out").addEventListener("click", async () => {
  if (!supabase) return;
  const { error } = await supabase.auth.signOut();
  if (error) toast(readableError(error), "error");
  showAuth();
});

document.querySelector("#refresh-button").addEventListener("click", () => refreshDashboard());
document.querySelectorAll(".tab[data-tab]").forEach((tab) => tab.addEventListener("click", () => {
  if (tab.disabled) return;
  activeTab = tab.dataset.tab;
  renderAll();
}));

document.addEventListener("submit", async (event) => {
  if (event.target.id !== "nomination-form") return;
  event.preventDefault();
  const button = event.target.querySelector('button[type="submit"]');
  const title = new FormData(event.target).get("title").toString().trim();
  button.disabled = true;
  try {
    const { error } = await supabase.rpc("submit_nomination", {
      p_night_id: dashboard.night.id,
      p_title: title,
    });
    if (error) throw error;
    toast("Nomination salvata: il titolo resta segreto finché non viene estratto.", "success");
    await refreshDashboard();
  } catch (error) {
    toast(readableError(error), "error");
    button.disabled = false;
  }
});

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-action]");
  if (!button || button.disabled) return;
  runAction(button.dataset.action, button);
});

async function initialize() {
  if (!configured) {
    showAuth();
    return;
  }
  try {
    const { data, error } = await supabase.auth.getSession();
    if (error) throw error;
    if (data.session?.user) await enterApp(data.session.user);
    else showAuth();
  } catch (error) {
    showAuth();
    toast(readableError(error), "error");
  }
}

window.setInterval(() => {
  if (currentUser && !loading) refreshDashboard(true);
}, 12000);

initialize();
