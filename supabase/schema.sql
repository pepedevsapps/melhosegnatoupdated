-- Serata Cinema: schema iniziale per un progetto Supabase vuoto.
-- Eseguire nel SQL Editor per inizializzare o aggiornare lo schema. Non inserire qui password o service_role key.

create table if not exists public.admin_bootstrap (
  singleton boolean primary key default true check (singleton),
  email text
);
insert into public.admin_bootstrap(singleton,email) values(true,null)
on conflict(singleton) do nothing;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,20}$'),
  role text not null default 'player' check (role in ('player','admin')),
  created_at timestamptz not null default now(),
  onboarding_completed boolean not null default false
);
alter table public.profiles add column if not exists onboarding_completed boolean not null default false;
create table if not exists public.film_categories (
  id integer generated always as identity primary key,
  name text not null unique
);
insert into public.film_categories(name) values
 ('Commedia'),('Drammatico'),('Fantascienza'),('Horror'),('Thriller'),
 ('Animazione'),('Azione'),('Fantasy'),('Cinema italiano'),('Cult'),
 ('Documentario'),('Musical'),('Romantico'),('Avventura'),('Crime'),
 ('Film in bianco e nero')
on conflict(name) do nothing;

create table if not exists public.movie_nights (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Serata cinema',
  created_by uuid not null references public.profiles(id),
  phase text not null default 'nominations'
    check (phase in ('nominations','leaderboard','complete')),
  revealed_count integer not null default 0 check (revealed_count >= 0),
  created_at timestamptz not null default now(),
  finished_at timestamptz
);
-- Categoria privata, visibile all'utente solo tramite get_my_assignment().
create table if not exists public.night_participants (
  night_id uuid not null references public.movie_nights(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  category_id integer not null references public.film_categories(id),
  primary key(night_id,user_id)
);
-- Stato pubblico sicuro: nessun titolo di film.
create table if not exists public.night_members (
  night_id uuid not null references public.movie_nights(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  has_nominated boolean not null default false,
  joined_at timestamptz not null default now(),
  primary key(night_id,user_id)
);
-- I titoli rimangono privati finché un RPC admin non ne estrae uno.
create table if not exists public.movie_nominations (
  id uuid primary key default gen_random_uuid(),
  night_id uuid not null references public.movie_nights(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  category_id integer not null references public.film_categories(id),
  title text not null check (char_length(title) between 2 and 140),
  normalized_title text not null,
  omdb_id text,
  status text not null default 'queued' check (status in ('queued','drawn')),
  created_at timestamptz not null default now(),
  unique(night_id,user_id),
  unique(night_id,normalized_title)
);
alter table public.movie_nominations add column if not exists omdb_id text;
create table if not exists public.drawn_films (
  id uuid primary key default gen_random_uuid(),
  night_id uuid not null references public.movie_nights(id) on delete cascade,
  nomination_id uuid not null unique references public.movie_nominations(id),
  title text not null,
  category_id integer not null references public.film_categories(id),
  status text not null default 'checking' check (status in ('checking','approved','rejected')),
  member_count integer not null check (member_count > 0),
  vote_count integer not null default 0 check (vote_count >= 0),
  rating_count integer not null default 0 check (rating_count >= 0),
  seen_count integer,
  drawn_at timestamptz not null default now(),
  decided_at timestamptz
);
alter table public.drawn_films add column if not exists vote_count integer not null default 0 check (vote_count >= 0);
create table if not exists public.drawn_film_metadata (
  drawn_film_id uuid primary key references public.drawn_films(id) on delete cascade,
  found boolean not null default true,
  imdb_id text,
  title text not null,
  year text,
  rated text,
  released text,
  runtime text,
  genre text,
  director text,
  actors text,
  plot text,
  language text,
  country text,
  awards text,
  poster_url text,
  imdb_rating text,
  imdb_votes text,
  metascore text,
  updated_at timestamptz not null default now()
);
create table if not exists public.omdb_cache (
  cache_key text primary key,
  payload jsonb not null,
  fetched_at timestamptz not null default now()
);
create table if not exists public.omdb_api_call_log (
  id bigint generated always as identity primary key,
  called_at timestamptz not null default now()
);
create index if not exists omdb_api_call_log_called_at_idx on public.omdb_api_call_log(called_at);
-- Le risposte individuali restano private; ai membri viene mostrato solo il conteggio aggregato.
create table if not exists public.seen_votes (
  drawn_film_id uuid not null references public.drawn_films(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  has_seen boolean not null,
  voted_at timestamptz not null default now(),
  primary key(drawn_film_id,user_id)
);
update public.drawn_films d set
  vote_count=(select count(*) from public.seen_votes sv where sv.drawn_film_id=d.id),
  seen_count=(select count(*) from public.seen_votes sv where sv.drawn_film_id=d.id and sv.has_seen);
create table if not exists public.movie_ratings (
  drawn_film_id uuid not null references public.drawn_films(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  rating numeric(2,1) not null check (
    rating >= 1 and rating <= 5 and rating * 2 = trunc(rating * 2)
  ),
  rated_at timestamptz not null default now(),
  primary key(drawn_film_id,user_id)
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path='' 
as $$
declare
  v_username text := lower(trim(coalesce(new.raw_user_meta_data->>'username','')));
  v_admin_email text;
  v_role text := 'player';
begin
  if v_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'Username non valido. Usa 3-20 lettere, numeri o underscore.';
  end if;
  if v_username = 'pepe1914' then
    select email into v_admin_email from public.admin_bootstrap where singleton=true;
    if v_admin_email is null or lower(v_admin_email) <> lower(new.email) then
      raise exception 'Username riservato.';
    end if;
    v_role := 'admin';
  end if;
  insert into public.profiles(id,username,role) values(new.id,v_username,v_role);
  return new;
end;
$$;
drop trigger if exists on_auth_user_created_profile on auth.users;
create trigger on_auth_user_created_profile after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_current_user_admin()
returns boolean language sql stable security definer set search_path='' 
as $$ select exists(select 1 from public.profiles where id=auth.uid() and role='admin'); $$;
create or replace function public.is_night_member(p_night_id uuid)
returns boolean language sql stable security definer set search_path='' 
as $$ select exists(select 1 from public.night_members where night_id=p_night_id and user_id=auth.uid()); $$;

create or replace function public.reserve_omdb_api_call(p_daily_limit integer)
returns boolean language plpgsql security definer set search_path=''
as $$
declare
  v_call_count integer;
begin
  if p_daily_limit < 1 or p_daily_limit > 950 then
    raise exception 'Limite OMDb non valida.';
  end if;
  -- A rolling window avoids double quota at a calendar midnight boundary.
  perform pg_advisory_xact_lock(824019492347::bigint);
  delete from public.omdb_api_call_log where called_at < now() - interval '24 hours';
  select count(*) into v_call_count from public.omdb_api_call_log
    where called_at >= now() - interval '24 hours';
  if v_call_count >= p_daily_limit then return false; end if;
  insert into public.omdb_api_call_log(called_at) values(now());
  return true;
end;
$$;

create or replace function public.start_movie_night()
returns uuid language plpgsql security definer set search_path='' 
as $$
declare
  v_night_id uuid := gen_random_uuid();
  v_categories integer[];
  v_category_count integer;
  v_person record;
  v_index integer := 0;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  if exists(select 1 from public.movie_nights where phase <> 'complete') then
    raise exception 'Concludi la serata attiva prima di crearne una nuova.';
  end if;
  select array_agg(id order by random()) into v_categories from public.film_categories;
  v_category_count := coalesce(array_length(v_categories,1),0);
  if v_category_count=0 then raise exception 'Nessuna categoria configurata.'; end if;
  insert into public.movie_nights(id,created_by) values(v_night_id,auth.uid());
  for v_person in select id from public.profiles order by random() loop
    v_index := v_index+1;
    insert into public.night_participants(night_id,user_id,category_id)
    values(v_night_id,v_person.id,v_categories[((v_index-1)%v_category_count)+1]);
    insert into public.night_members(night_id,user_id) values(v_night_id,v_person.id);
  end loop;
  return v_night_id;
end;
$$;

create or replace function public.get_my_assignment(p_night_id uuid)
returns table(category_id integer,category_name text)
language plpgsql stable security definer set search_path='' 
as $$
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  return query
    select c.id,c.name from public.night_participants np
    join public.film_categories c on c.id=np.category_id
    where np.night_id=p_night_id and np.user_id=auth.uid();
end;
$$;

drop function if exists public.submit_nomination(uuid,text);
create or replace function public.submit_nomination(p_night_id uuid,p_title text,p_omdb_id text)
returns void language plpgsql security definer set search_path='' 
as $$
declare
  v_category_id integer;
  v_phase text;
  v_title text := trim(coalesce(p_title,''));
  v_normalized text;
begin
  if auth.uid() is null then raise exception 'Accedi per inviare una nomination.'; end if;
  select phase into v_phase from public.movie_nights where id=p_night_id for update;
  if v_phase is distinct from 'nominations' then raise exception 'Le nomination sono chiuse.'; end if;
  select category_id into v_category_id from public.night_participants
    where night_id=p_night_id and user_id=auth.uid();
  if v_category_id is null then raise exception 'Non fai parte di questa serata.'; end if;
  if char_length(v_title)<2 or char_length(v_title)>140 then
    raise exception 'Inserisci un titolo tra 2 e 140 caratteri.';
  end if;
  if exists(select 1 from public.night_members where night_id=p_night_id and user_id=auth.uid() and has_nominated) then
    raise exception 'Hai già inviato la nomination.';
  end if;
  v_normalized := lower(regexp_replace(v_title,'\s+',' ','g'));
  insert into public.movie_nominations(night_id,user_id,category_id,title,normalized_title,omdb_id)
  values(p_night_id,auth.uid(),v_category_id,v_title,v_normalized,nullif(trim(p_omdb_id),''));
  update public.night_members set has_nominated=true
    where night_id=p_night_id and user_id=auth.uid();
end;
$$;
create or replace function public.submit_nomination(p_night_id uuid,p_title text)
returns void language sql security definer set search_path=''
as $$ select public.submit_nomination(p_night_id,p_title,null::text); $$;

create or replace function public.admin_draw_next(p_night_id uuid)
returns uuid language plpgsql security definer set search_path='' 
as $$
declare
  v_phase text;
  v_nomination record;
  v_film_id uuid := gen_random_uuid();
  v_member_count integer;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  select phase into v_phase from public.movie_nights where id=p_night_id for update;
  if v_phase is distinct from 'nominations' then raise exception 'La fase nomination è terminata.'; end if;
  if exists(select 1 from public.night_members where night_id=p_night_id and not has_nominated) then
    raise exception 'Attendi che tutti inviino una nomination.';
  end if;
  if exists(select 1 from public.drawn_films where night_id=p_night_id and status='checking') then
    raise exception 'Completa prima il voto visto/non visto.';
  end if;
  if exists(select 1 from public.drawn_films where night_id=p_night_id and status='rejected') then
    raise exception 'Il responsabile della nomination deve sostituire il titolo rifiutato.';
  end if;
  if exists(select 1 from public.drawn_films d where d.night_id=p_night_id and d.status='approved'
    and (select count(*) from public.movie_ratings r where r.drawn_film_id=d.id)<d.member_count) then
    raise exception 'Aspetta che tutti votino il film approvato.';
  end if;
  select n.id,n.title,n.category_id into v_nomination
  from public.movie_nominations n
  where n.night_id=p_night_id and n.status='queued'
  order by random() limit 1 for update skip locked;
  if v_nomination.id is null then raise exception 'Il pool delle nomination è vuoto.'; end if;
  select count(*) into v_member_count from public.night_members where night_id=p_night_id;
  update public.movie_nominations set status='drawn' where id=v_nomination.id;
  insert into public.drawn_films(id,night_id,nomination_id,title,category_id,member_count,vote_count,seen_count)
  values(v_film_id,p_night_id,v_nomination.id,v_nomination.title,v_nomination.category_id,v_member_count,0,0);
  return v_film_id;
end;
$$;



create or replace function public.submit_seen_vote(p_drawn_film_id uuid,p_has_seen boolean)
returns text language plpgsql security definer set search_path='' 
as $$
declare
  v_night_id uuid;
  v_phase text;
  v_status text;
  v_member_count integer;
  v_vote_count integer;
  v_seen_count integer;
  v_next_status text;
  v_drawn_at timestamptz;
begin
  if auth.uid() is null then raise exception 'Accedi per votare.'; end if;
  select night_id,status,member_count,drawn_at into v_night_id,v_status,v_member_count,v_drawn_at
    from public.drawn_films where id=p_drawn_film_id for update;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  -- Serializza le modifiche del voto con il sorteggio del film successivo.
  select phase into v_phase from public.movie_nights where id=v_night_id for update;
  if v_phase is distinct from 'nominations' then raise exception 'Il periodo per modificare il voto è terminato.'; end if;
  if v_status not in ('checking','approved','rejected') then
    raise exception 'Il voto di verifica è già concluso.';
  end if;
  if exists(select 1 from public.drawn_films d where d.night_id=v_night_id
    and (d.drawn_at > v_drawn_at or (d.drawn_at=v_drawn_at and d.id>p_drawn_film_id))) then
    raise exception 'Il voto di questo film è chiuso perché è già stato estratto il successivo.';
  end if;
  insert into public.seen_votes(drawn_film_id,user_id,has_seen)
  values(p_drawn_film_id,auth.uid(),p_has_seen)
  on conflict(drawn_film_id,user_id)
  do update set has_seen=excluded.has_seen,voted_at=now();
  select count(*),count(*) filter(where has_seen)
    into v_vote_count,v_seen_count
    from public.seen_votes where drawn_film_id=p_drawn_film_id;
  if v_vote_count=v_member_count then
    -- Il titolo viene rifiutato solo quando più del 55% dichiara di averlo già visto.
    v_next_status := case when v_seen_count*100 > v_member_count*55 then 'rejected' else 'approved' end;
    if v_next_status='rejected' and v_status='approved' then
      delete from public.movie_ratings where drawn_film_id=p_drawn_film_id;
      update public.drawn_films set rating_count=0 where id=p_drawn_film_id;
    end if;
    update public.drawn_films set vote_count=v_vote_count,seen_count=v_seen_count,
      status=v_next_status,decided_at=now()
      where id=p_drawn_film_id;
    return v_next_status;
  end if;
  update public.drawn_films set vote_count=v_vote_count,seen_count=v_seen_count,
    status='checking',decided_at=null where id=p_drawn_film_id;
  return 'checking';
end;
$$;

drop function if exists public.replace_rejected_nomination(uuid,text);
create or replace function public.replace_rejected_nomination(p_drawn_film_id uuid,p_title text,p_omdb_id text)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_nomination_id uuid;
  v_status text;
  v_phase text;
  v_revealed_count integer;
  v_title text := trim(coalesce(p_title,''));
  v_normalized text;
begin
  if auth.uid() is null then raise exception 'Accedi per sostituire il film.'; end if;
  if char_length(v_title)<2 or char_length(v_title)>140 then
    raise exception 'Inserisci un titolo tra 2 e 140 caratteri.';
  end if;
  select d.night_id,d.nomination_id,d.status into v_night_id,v_nomination_id,v_status
    from public.drawn_films d where d.id=p_drawn_film_id for update;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if v_status <> 'rejected' then
    raise exception 'La sostituzione è disponibile solo dopo un voto sfavorevole.';
  end if;
  select n.status into v_status from public.movie_nominations n
    where n.id=v_nomination_id and n.user_id=auth.uid() for update;
  if not found then raise exception 'Solo chi ha proposto il film può sostituirlo.'; end if;
  select n.phase,n.revealed_count into v_phase,v_revealed_count
    from public.movie_nights n where n.id=v_night_id for update;
  if v_phase='complete' and v_revealed_count=0 then
    -- Consenti il recupero dei rifiuti conclusi dal vecchio flusso a soglia 60%.
    update public.movie_nights set phase='nominations',finished_at=null where id=v_night_id;
  elsif v_phase <> 'nominations' then
    raise exception 'La fase nomination è terminata.';
  end if;
  v_normalized := lower(regexp_replace(v_title,'\s+',' ','g'));
  begin
    update public.movie_nominations set title=v_title,normalized_title=v_normalized,
      omdb_id=nullif(trim(p_omdb_id),'')
      where id=v_nomination_id;
  exception when unique_violation then
    raise exception 'Questo titolo è già stato nominato nella serata.';
  end;
  delete from public.seen_votes where drawn_film_id=p_drawn_film_id;
  delete from public.movie_ratings where drawn_film_id=p_drawn_film_id;
  update public.drawn_films set title=v_title,status='checking',vote_count=0,seen_count=0,
    rating_count=0,decided_at=null where id=p_drawn_film_id;
end;
$$;
create or replace function public.replace_rejected_nomination(p_drawn_film_id uuid,p_title text)
returns void language sql security definer set search_path=''
as $$ select public.replace_rejected_nomination(p_drawn_film_id,p_title,null::text); $$;

create or replace function public.get_my_seen_vote(p_drawn_film_id uuid)
returns boolean language sql stable security definer set search_path='' 
as $$
  select sv.has_seen from public.seen_votes sv
  join public.drawn_films d on d.id=sv.drawn_film_id
  where sv.drawn_film_id=p_drawn_film_id and sv.user_id=auth.uid()
    and public.is_night_member(d.night_id) limit 1;
$$;

create or replace function public.get_my_rating(p_drawn_film_id uuid)
returns numeric language sql stable security definer set search_path='' 
as $$
  select r.rating from public.movie_ratings r
  join public.drawn_films d on d.id=r.drawn_film_id
  where r.drawn_film_id=p_drawn_film_id and r.user_id=auth.uid()
    and public.is_night_member(d.night_id) limit 1;
$$;

create or replace function public.cast_movie_rating(p_drawn_film_id uuid,p_rating numeric)
returns void language plpgsql security definer set search_path='' 
as $$
declare
  v_night_id uuid;
  v_status text;
  v_phase text;
begin
  if auth.uid() is null then raise exception 'Accedi per votare.'; end if;
  if p_rating < 1 or p_rating > 5 or p_rating*2 <> trunc(p_rating*2) then
    raise exception 'Il voto deve essere da 1 a 5, con incrementi di mezzo popcorn.';
  end if;
  select night_id,status into v_night_id,v_status
    from public.drawn_films where id=p_drawn_film_id for update;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if v_status <> 'approved' then raise exception 'Il film non è stato approvato.'; end if;
  if (select phase from public.movie_nights where id=v_night_id) <> 'nominations' then
    raise exception 'La classifica è già stata sbloccata.';
  end if;
  insert into public.movie_ratings(drawn_film_id,user_id,rating)
    values(p_drawn_film_id,auth.uid(),p_rating)
    on conflict(drawn_film_id,user_id)
    do update set rating=excluded.rating,rated_at=now();
  update public.drawn_films set rating_count=(
    select count(*) from public.movie_ratings where drawn_film_id=p_drawn_film_id
  ) where id=p_drawn_film_id;
  if not exists(select 1 from public.movie_nominations where night_id=v_night_id and status='queued')
     and not exists(select 1 from public.drawn_films where night_id=v_night_id and status='checking')
     and not exists(select 1 from public.drawn_films where night_id=v_night_id and status='rejected')
     and not exists(select 1 from public.drawn_films d where d.night_id=v_night_id and d.status='approved'
        and (select count(*) from public.movie_ratings r where r.drawn_film_id=d.id)<d.member_count) then
    update public.movie_nights set phase='leaderboard' where id=v_night_id and phase='nominations';
  end if;
end;
$$;

create or replace function public.get_leaderboard_state(p_night_id uuid)
returns table(unlocked boolean,total_films integer,revealed integer,phase text)
language plpgsql stable security definer set search_path='' 
as $$
declare
  v_phase text;
  v_revealed integer;
  v_total integer;
  v_ready boolean;
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  select n.phase,n.revealed_count into v_phase,v_revealed
    from public.movie_nights n where n.id=p_night_id;
  if v_phase is null then raise exception 'Serata non trovata.'; end if;
  select count(*) into v_total from public.drawn_films
    where night_id=p_night_id and status='approved';
  v_ready := v_phase in ('leaderboard','complete')
    and not exists(select 1 from public.movie_nominations where night_id=p_night_id and status='queued')
    and not exists(select 1 from public.drawn_films where night_id=p_night_id and status='checking')
    and not exists(select 1 from public.drawn_films where night_id=p_night_id and status='rejected')
    and not exists(select 1 from public.drawn_films d where d.night_id=p_night_id and d.status='approved'
      and (select count(*) from public.movie_ratings r where r.drawn_film_id=d.id)<d.member_count);
  return query select v_ready,v_total,v_revealed,v_phase;
end;
$$;

drop function if exists public.get_revealed_movies(uuid);
create function public.get_revealed_movies(p_night_id uuid)
returns table(drawn_film_id uuid,title text,category_name text,average_rating numeric,"position" integer,vote_count bigint,submitted_by text,poster_url text)
language plpgsql stable security definer set search_path='' 
as $$
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  if not exists(select 1 from public.get_leaderboard_state(p_night_id) s where s.unlocked) then
    raise exception 'La classifica non è ancora disponibile.';
  end if;
  return query
    with scores as (
      select d.id,d.nomination_id,d.title,c.name as category_name,
        round(avg(r.rating),2)::numeric as average_rating,count(r.user_id)::bigint as vote_count
      from public.drawn_films d
      join public.film_categories c on c.id=d.category_id
      join public.movie_ratings r on r.drawn_film_id=d.id
      where d.night_id=p_night_id and d.status='approved'
      group by d.id,d.nomination_id,d.title,c.name
    ), ranked as (
      select s.*,row_number() over(order by s.average_rating desc,s.title asc)::integer as position
      from scores s
    ), reveal_state as (
      select n.revealed_count,(select count(*) from ranked)::integer as total
      from public.movie_nights n where n.id=p_night_id
    )
    select r.id,r.title,r.category_name,r.average_rating,r.position,r.vote_count,
      p.username,m.poster_url
    from ranked r
    join public.movie_nominations n on n.id=r.nomination_id
    join public.profiles p on p.id=n.user_id
    left join public.drawn_film_metadata m on m.drawn_film_id=r.id
    cross join reveal_state rs
    where r.position > rs.total-rs.revealed_count
    order by r.position desc;
end;
$$;

create or replace function public.admin_reveal_next_rank(p_night_id uuid)
returns table(drawn_film_id uuid,title text,category_name text,average_rating numeric,"position" integer,total_films integer)
language plpgsql security definer set search_path='' 
as $$
declare
  v_phase text;
  v_revealed integer;
  v_total integer;
  v_position integer;
  v_film_id uuid;
  v_title text;
  v_category text;
  v_average numeric;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  select n.phase,n.revealed_count into v_phase,v_revealed
    from public.movie_nights n where n.id=p_night_id for update;
  if v_phase is null or not exists(
    select 1 from public.get_leaderboard_state(p_night_id) s where s.unlocked
  ) then raise exception 'La classifica non è pronta.'; end if;
  select count(*) into v_total from public.drawn_films
    where night_id=p_night_id and status='approved';
  if v_revealed>=v_total then raise exception 'Tutte le posizioni sono già state rivelate.'; end if;
  v_position := v_total-v_revealed;
  with scores as (
    select d.id,d.title,c.name as category_name,round(avg(r.rating),2)::numeric as average_rating
    from public.drawn_films d
    join public.film_categories c on c.id=d.category_id
    join public.movie_ratings r on r.drawn_film_id=d.id
    where d.night_id=p_night_id and d.status='approved'
    group by d.id,d.title,c.name
  ), ranked as (
    select s.*,row_number() over(order by s.average_rating desc,s.title asc)::integer as place
    from scores s
  )
  select r.id,r.title,r.category_name,r.average_rating
    into v_film_id,v_title,v_category,v_average
    from ranked r where r.place=v_position;
  if v_film_id is null then raise exception 'Posizione non disponibile.'; end if;
  update public.movie_nights
    set revealed_count=v_revealed+1,
        phase=case when v_revealed+1=v_total then 'complete' else 'leaderboard' end,
        finished_at=case when v_revealed+1=v_total then now() else finished_at end
    where id=p_night_id;
  return query select v_film_id,v_title,v_category,v_average,v_position,v_total;
end;
$$;



-- Accesso in lettura limitato. Tutte le scritture operative passano dagli RPC.
alter table public.admin_bootstrap enable row level security;
alter table public.profiles enable row level security;
alter table public.film_categories enable row level security;
alter table public.movie_nights enable row level security;
alter table public.night_participants enable row level security;
alter table public.night_members enable row level security;
alter table public.movie_nominations enable row level security;
alter table public.drawn_films enable row level security;
alter table public.drawn_film_metadata enable row level security;
alter table public.omdb_cache enable row level security;
alter table public.omdb_api_call_log enable row level security;
alter table public.seen_votes enable row level security;
alter table public.movie_ratings enable row level security;

drop policy if exists profiles_read_authenticated on public.profiles;
create policy profiles_read_authenticated on public.profiles
  for select to authenticated using(true);
drop policy if exists categories_read_authenticated on public.film_categories;
create policy categories_read_authenticated on public.film_categories
  for select to authenticated using(true);
drop policy if exists nights_read_authenticated on public.movie_nights;
create policy nights_read_authenticated on public.movie_nights
  for select to authenticated using(true);
drop policy if exists members_read_authenticated on public.night_members;
create policy members_read_authenticated on public.night_members
  for select to authenticated using(true);
drop policy if exists own_nomination_read on public.movie_nominations;
create policy own_nomination_read on public.movie_nominations
  for select to authenticated using(user_id=auth.uid());
-- After a nomination is drawn, members can see who submitted that revealed film.
drop policy if exists drawn_nomination_submitter_read on public.movie_nominations;
create policy drawn_nomination_submitter_read on public.movie_nominations
  for select to authenticated using(exists(
    select 1 from public.drawn_films d
    where d.nomination_id=movie_nominations.id and public.is_night_member(d.night_id)
  ));
drop policy if exists member_draws_read on public.drawn_films;
create policy member_draws_read on public.drawn_films
  for select to authenticated using(public.is_night_member(night_id));
drop policy if exists member_drawn_film_metadata_read on public.drawn_film_metadata;
create policy member_drawn_film_metadata_read on public.drawn_film_metadata
  for select to authenticated using(exists(
    select 1 from public.drawn_films d
    where d.id=drawn_film_id and public.is_night_member(d.night_id)
  ));
drop policy if exists own_seen_vote_read on public.seen_votes;
create policy own_seen_vote_read on public.seen_votes
  for select to authenticated using(user_id=auth.uid());
drop policy if exists own_rating_read on public.movie_ratings;
create policy own_rating_read on public.movie_ratings
  for select to authenticated using(user_id=auth.uid());

revoke all on public.admin_bootstrap from anon,authenticated;
revoke all on public.omdb_cache,public.omdb_api_call_log from public,anon,authenticated;
grant all on public.omdb_cache,public.omdb_api_call_log to service_role;
revoke all on public.drawn_film_metadata from public,anon,authenticated;
grant select on public.drawn_film_metadata to authenticated;
revoke insert,update,delete on public.profiles,public.film_categories,public.movie_nights,
  public.night_participants,public.night_members,public.movie_nominations,
  public.drawn_films,public.seen_votes,public.movie_ratings from anon,authenticated;
grant select on public.profiles,public.film_categories,public.movie_nights,
  public.night_members,public.movie_nominations,public.drawn_films,
  public.seen_votes,public.movie_ratings to authenticated;
revoke all on public.night_participants from anon,authenticated;

-- Le RPC helper restituisce solo se l'utente corrente appartiene alla serata.
revoke all on function public.handle_new_user() from public,anon,authenticated;
revoke all on function public.is_current_user_admin() from public,anon,authenticated;
revoke all on function public.is_night_member(uuid) from public,anon,authenticated;
revoke all on function public.start_movie_night() from public,anon,authenticated;
revoke all on function public.get_my_assignment(uuid) from public,anon,authenticated;
revoke all on function public.submit_nomination(uuid,text,text) from public,anon,authenticated;
revoke all on function public.submit_nomination(uuid,text) from public,anon,authenticated;
revoke all on function public.admin_draw_next(uuid) from public,anon,authenticated;
revoke all on function public.submit_seen_vote(uuid,boolean) from public,anon,authenticated;
revoke all on function public.replace_rejected_nomination(uuid,text,text) from public,anon,authenticated;
revoke all on function public.replace_rejected_nomination(uuid,text) from public,anon,authenticated;
revoke all on function public.reserve_omdb_api_call(integer) from public,anon,authenticated;
revoke all on function public.get_my_seen_vote(uuid) from public,anon,authenticated;
revoke all on function public.get_my_rating(uuid) from public,anon,authenticated;
revoke all on function public.cast_movie_rating(uuid,numeric) from public,anon,authenticated;
revoke all on function public.get_leaderboard_state(uuid) from public,anon,authenticated;
revoke all on function public.get_revealed_movies(uuid) from public,anon,authenticated;
revoke all on function public.admin_reveal_next_rank(uuid) from public,anon,authenticated;

grant execute on function public.is_night_member(uuid) to authenticated;
grant execute on function public.start_movie_night() to authenticated;
grant execute on function public.get_my_assignment(uuid) to authenticated;
grant execute on function public.submit_nomination(uuid,text,text) to authenticated;
grant execute on function public.submit_nomination(uuid,text) to authenticated;
grant execute on function public.admin_draw_next(uuid) to authenticated;
grant execute on function public.submit_seen_vote(uuid,boolean) to authenticated;
grant execute on function public.replace_rejected_nomination(uuid,text,text) to authenticated;
grant execute on function public.replace_rejected_nomination(uuid,text) to authenticated;
grant execute on function public.reserve_omdb_api_call(integer) to service_role;
grant execute on function public.get_my_seen_vote(uuid) to authenticated;
grant execute on function public.get_my_rating(uuid) to authenticated;
grant execute on function public.cast_movie_rating(uuid,numeric) to authenticated;
grant execute on function public.get_leaderboard_state(uuid) to authenticated;
grant execute on function public.get_revealed_movies(uuid) to authenticated;
grant execute on function public.admin_reveal_next_rank(uuid) to authenticated;

-- Additive category draft and pick-bonus scoring migration.
alter table public.movie_nights drop constraint if exists movie_nights_phase_check;
alter table public.movie_nights add constraint movie_nights_phase_check
  check (phase in ('category_draft','nominations','leaderboard','complete'));
alter table public.night_members add column if not exists pick_position integer;
alter table public.night_participants alter column category_id drop not null;
alter table public.night_participants add column if not exists selected_at timestamptz;

-- Preserve a stable order for existing nights; newly started nights receive a randomized order once.
with positioned as (
  select night_id,user_id,row_number() over(partition by night_id order by joined_at,user_id)::integer as pick_position
  from public.night_members where pick_position is null
)
update public.night_members nm set pick_position=p.pick_position
from positioned p where p.night_id=nm.night_id and p.user_id=nm.user_id;
alter table public.night_members alter column pick_position set not null;
create unique index if not exists night_members_pick_position_uidx
  on public.night_members(night_id,pick_position);
update public.night_participants set selected_at=now()
where category_id is not null and selected_at is null;

create or replace function public.start_movie_night()
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid := gen_random_uuid();
  v_participant_count integer;
  v_category_count integer;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(73104811223::bigint);
  if exists(select 1 from public.movie_nights where phase <> 'complete') then
    raise exception 'Concludi la serata attiva prima di crearne una nuova.';
  end if;
  select count(*) into v_participant_count from public.profiles;
  select count(*) into v_category_count from public.film_categories;
  if v_participant_count=0 then raise exception 'Nessun partecipante attivo.'; end if;
  if v_participant_count>v_category_count then
    raise exception 'Servono almeno tante categorie quanti sono i partecipanti.';
  end if;
  insert into public.movie_nights(id,created_by,phase)
  values(v_night_id,auth.uid(),'category_draft');
  with randomized_order as (
    select p.id,row_number() over(order by random(),p.id)::integer as pick_position
    from public.profiles p
  )
  insert into public.night_members(night_id,user_id,pick_position)
  select v_night_id,id,pick_position from randomized_order;
  insert into public.night_participants(night_id,user_id,category_id)
  select v_night_id,user_id,null from public.night_members where night_id=v_night_id;
  return v_night_id;
end;
$$;

create or replace function public.get_category_draft_state(p_night_id uuid)
returns table(
  pick_position integer,user_id uuid,username text,category_id integer,category_name text,
  picked_at timestamptz,pick_bonus numeric,is_current_turn boolean,is_me boolean
)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_participant_count integer;
  v_current_user uuid;
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  select count(*) into v_participant_count from public.night_members nm where nm.night_id=p_night_id;
  select nm.user_id into v_current_user
  from public.night_members nm
  join public.night_participants np on np.night_id=nm.night_id and np.user_id=nm.user_id
  where nm.night_id=p_night_id and np.category_id is null
  order by nm.pick_position limit 1;
  return query
  select nm.pick_position,nm.user_id,p.username,np.category_id,c.name,np.selected_at,
    case when v_participant_count<=1 then 0::numeric
      else 0.5::numeric*(nm.pick_position-1)::numeric/(v_participant_count-1)::numeric end,
    nm.user_id=v_current_user,nm.user_id=auth.uid()
  from public.night_members nm
  join public.profiles p on p.id=nm.user_id
  left join public.night_participants np on np.night_id=nm.night_id and np.user_id=nm.user_id
  left join public.film_categories c on c.id=np.category_id
  where nm.night_id=p_night_id
  order by nm.pick_position;
end;
$$;

create or replace function public.select_draft_category(p_night_id uuid,p_category_id integer)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_phase text;
  v_current_user uuid;
begin
  if auth.uid() is null then raise exception 'Accedi per scegliere una categoria.'; end if;
  select n.phase into v_phase from public.movie_nights n where n.id=p_night_id for update;
  if v_phase is distinct from 'category_draft' then raise exception 'La scelta delle categorie è terminata.'; end if;
  select nm.user_id into v_current_user
  from public.night_members nm
  join public.night_participants np on np.night_id=nm.night_id and np.user_id=nm.user_id
  where nm.night_id=p_night_id and np.category_id is null
  order by nm.pick_position limit 1;
  if v_current_user is null then raise exception 'Tutte le categorie sono già state scelte.'; end if;
  if v_current_user<>auth.uid() then raise exception 'Non è il tuo turno di scegliere una categoria.'; end if;
  if not exists(select 1 from public.film_categories c where c.id=p_category_id) then
    raise exception 'Categoria non disponibile.';
  end if;
  if exists(select 1 from public.night_participants np
    where np.night_id=p_night_id and np.category_id=p_category_id) then
    raise exception 'Questa categoria è già stata scelta.';
  end if;
  update public.night_participants np set category_id=p_category_id,selected_at=now()
  where np.night_id=p_night_id and np.user_id=auth.uid() and np.category_id is null;
  if not found then raise exception 'Hai già scelto una categoria.'; end if;
  if not exists(select 1 from public.night_participants np
    where np.night_id=p_night_id and np.category_id is null) then
    update public.movie_nights set phase='nominations' where id=p_night_id;
  end if;
end;
$$;

create or replace function public.cast_movie_rating(p_drawn_film_id uuid,p_rating numeric)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_status text;
  v_phase text;
begin
  if auth.uid() is null then raise exception 'Accedi per votare.'; end if;
  if p_rating is null or p_rating<1 or p_rating>5 or p_rating*2<>trunc(p_rating*2) then
    raise exception 'Il voto deve essere da 1 a 5, con incrementi di mezzo popcorn.';
  end if;
  select d.night_id,d.status into v_night_id,v_status
  from public.drawn_films d where d.id=p_drawn_film_id for update;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if v_status<>'approved' then raise exception 'Il film non è stato approvato.'; end if;
  select n.phase into v_phase from public.movie_nights n where n.id=v_night_id for update;
  if v_phase is distinct from 'nominations' then
    raise exception 'La classifica è già stata finalizzata.';
  end if;
  -- The composite primary key keeps one row per participant and film; upsert preserves own-rating edits.
  insert into public.movie_ratings(drawn_film_id,user_id,rating)
  values(p_drawn_film_id,auth.uid(),p_rating)
  on conflict(drawn_film_id,user_id) do update set rating=excluded.rating,rated_at=now();
  update public.drawn_films d set rating_count=(
    select count(*) from public.movie_ratings r where r.drawn_film_id=p_drawn_film_id
  ) where d.id=p_drawn_film_id;
end;
$$;

create or replace function public.finalize_movie_night(p_night_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_phase text;
  v_revealed integer;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  select n.phase into v_phase from public.movie_nights n where n.id=p_night_id for update;
  if v_phase is null or v_phase not in ('nominations','leaderboard') then
    raise exception 'La serata non è pronta per essere finalizzata.';
  end if;
  if exists(select 1 from public.night_members nm
    where nm.night_id=p_night_id and not nm.has_nominated)
    or exists(select 1 from public.movie_nominations n
      where n.night_id=p_night_id and n.status='queued') then
    raise exception 'Estrai prima tutte le nomination.';
  end if;
  if exists(select 1 from public.drawn_films d
    where d.night_id=p_night_id and d.status<>'approved') then
    raise exception 'Completa la verifica dei film prima di finalizzare.';
  end if;
  select count(*) into v_revealed from public.drawn_films d
    where d.night_id=p_night_id and d.status='approved';
  update public.movie_nights set phase='complete',revealed_count=v_revealed,finished_at=now()
  where id=p_night_id;
end;
$$;

create or replace function public.get_leaderboard_state(p_night_id uuid)
returns table(unlocked boolean,total_films integer,revealed integer,phase text)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_phase text;
  v_total integer;
  v_revealed integer;
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  select n.phase,n.revealed_count into v_phase,v_revealed
    from public.movie_nights n where n.id=p_night_id;
  if v_phase is null then raise exception 'Serata non trovata.'; end if;
  select count(*) into v_total from public.drawn_films d
    where d.night_id=p_night_id and d.status='approved';
  return query select v_phase='complete',v_total,case when v_phase='complete' then v_total else v_revealed end,v_phase;
end;
$$;

create or replace function public.calculate_night_film_scores(p_night_id uuid)
returns table(
  drawn_film_id uuid,title text,category_name text,selected_by text,pick_position integer,
  rating_count bigint,average_rating numeric,pick_bonus numeric,final_score numeric,rank_position integer,poster_url text
)
language sql stable security definer set search_path=''
as $$
  with participant_totals as (
    select count(*)::integer as participant_count from public.night_members nm where nm.night_id=p_night_id
  ), film_averages as (
    select d.id,d.title,c.name as category_name,selector.username as selected_by,
      selector_order.pick_position,count(r.user_id)::bigint as rating_count,avg(r.rating)::numeric as average_rating,
      case when pt.participant_count<=1 then 0::numeric
        else 0.5::numeric*(selector_order.pick_position-1)::numeric/(pt.participant_count-1)::numeric end as pick_bonus,
      m.poster_url
    from public.drawn_films d
    join public.film_categories c on c.id=d.category_id
    cross join participant_totals pt
    left join lateral (
      select nm.user_id,nm.pick_position from public.night_participants np
      join public.night_members nm on nm.night_id=np.night_id and nm.user_id=np.user_id
      where np.night_id=d.night_id and np.category_id=d.category_id
      order by nm.pick_position limit 1
    ) selector_order on true
    left join public.profiles selector on selector.id=selector_order.user_id
    left join public.drawn_film_metadata m on m.drawn_film_id=d.id
    left join public.movie_ratings r on r.drawn_film_id=d.id
    where d.night_id=p_night_id and d.status='approved'
    group by d.id,d.title,c.name,selector.username,selector_order.pick_position,pt.participant_count,m.poster_url
  ), film_scores as (
    select f.*,case when f.average_rating is null then null
      else least(5::numeric,f.average_rating+f.pick_bonus) end as raw_final_score
    from film_averages f
  ), ranked as (
    select s.*,case when s.raw_final_score is null then null::integer
      else rank() over(order by s.raw_final_score desc nulls last,s.average_rating desc nulls last)::integer end as raw_rank
    from film_scores s
  )
  select r.id,r.title,r.category_name,r.selected_by,r.pick_position,r.rating_count,
    round(r.average_rating,2),round(r.pick_bonus,2),round(r.raw_final_score,2),r.raw_rank,r.poster_url
  from ranked r
  order by r.raw_final_score desc nulls last,r.average_rating desc nulls last,r.title asc;
$$;

create or replace function public.get_provisional_leaderboard(p_night_id uuid)
returns table(
  drawn_film_id uuid,title text,category_name text,selected_by text,pick_position integer,
  rating_count bigint,average_rating numeric,pick_bonus numeric,final_score numeric,rank_position integer,poster_url text
)
language plpgsql stable security definer set search_path=''
as $$
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  if not exists(select 1 from public.movie_nights n where n.id=p_night_id and n.phase<>'complete') then
    raise exception 'La classifica provvisoria non è disponibile.';
  end if;
  return query select s.* from public.calculate_night_film_scores(p_night_id) s;
end;
$$;

drop function if exists public.get_revealed_movies(uuid);
create function public.get_revealed_movies(p_night_id uuid)
returns table(
  drawn_film_id uuid,title text,category_name text,selected_by text,pick_position integer,
  rating_count bigint,average_rating numeric,pick_bonus numeric,final_score numeric,rank_position integer,poster_url text
)
language plpgsql stable security definer set search_path=''
as $$
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  if not exists(select 1 from public.movie_nights n where n.id=p_night_id and n.phase='complete') then
    raise exception 'La classifica finale non è ancora stata pubblicata.';
  end if;
  return query select s.* from public.calculate_night_film_scores(p_night_id) s;
end;
$$;

-- The category picker sees the shared draft state through an RPC; raw private assignments stay inaccessible.
revoke all on function public.calculate_night_film_scores(uuid) from public,anon,authenticated;
revoke all on function public.get_category_draft_state(uuid) from public,anon,authenticated;
revoke all on function public.select_draft_category(uuid,integer) from public,anon,authenticated;
revoke all on function public.finalize_movie_night(uuid) from public,anon,authenticated;
revoke all on function public.get_provisional_leaderboard(uuid) from public,anon,authenticated;
revoke all on function public.admin_reveal_next_rank(uuid) from public,anon,authenticated;
grant execute on function public.get_category_draft_state(uuid) to authenticated;
grant execute on function public.select_draft_category(uuid,integer) to authenticated;
grant execute on function public.finalize_movie_night(uuid) to authenticated;
grant execute on function public.get_provisional_leaderboard(uuid) to authenticated;
grant execute on function public.get_revealed_movies(uuid) to authenticated;

-- Users can only mark their own first-login walkthrough as completed.
create or replace function public.complete_onboarding()
returns void language plpgsql security definer set search_path=''
as $$
begin
  if auth.uid() is null then raise exception 'Accedi per completare il tutorial.'; end if;
  update public.profiles set onboarding_completed=true where id=auth.uid();
  if not found then raise exception 'Profilo non trovato.'; end if;
end;
$$;
revoke all on function public.complete_onboarding() from public,anon,authenticated;
grant execute on function public.complete_onboarding() to authenticated;
