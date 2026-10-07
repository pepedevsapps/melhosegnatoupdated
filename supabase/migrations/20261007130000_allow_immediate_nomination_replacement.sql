-- Let a nomination owner replace the movie as soon as the seen-vote threshold
-- is crossed, even when the nomination has not been drawn yet.
create or replace function public.replace_nomination_after_seen_vote(
  p_nomination_id uuid,p_title text,p_omdb_id text
)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_owner_id uuid;
  v_current_normalized text;
  v_phase text;
  v_member_count integer;
  v_seen_count integer;
  v_drawn_film_id uuid;
  v_title text := trim(coalesce(p_title,''));
  v_normalized text;
begin
  if auth.uid() is null then raise exception 'Accedi per sostituire la nomination.'; end if;
  if char_length(v_title)<2 or char_length(v_title)>140 then
    raise exception 'Inserisci un titolo tra 2 e 140 caratteri.';
  end if;
  select n.night_id into v_night_id from public.movie_nominations n where n.id=p_nomination_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Nomination o serata non disponibili.';
  end if;

  select mn.phase into v_phase
  from public.movie_nights mn where mn.id=v_night_id for update;
  if v_phase is distinct from 'nominations' then
    raise exception 'Le sostituzioni sono chiuse per questa serata.';
  end if;
  if not public.is_night_member(v_night_id) then
    raise exception 'Non fai più parte di questa serata.';
  end if;

  select n.user_id,n.normalized_title
    into v_owner_id,v_current_normalized
  from public.movie_nominations n
  where n.id=p_nomination_id and n.night_id=v_night_id for update;
  if not found then raise exception 'Nomination non disponibile.'; end if;
  if v_owner_id<>auth.uid() then
    raise exception 'Solo chi ha inviato la nomination può sostituirla.';
  end if;

  select count(*)::integer into v_member_count
  from public.night_members nm where nm.night_id=v_night_id;
  select count(*) filter(where nsv.has_seen)::integer into v_seen_count
  from public.nomination_seen_votes nsv
  join public.night_members nm on nm.night_id=v_night_id and nm.user_id=nsv.user_id
  where nsv.nomination_id=p_nomination_id;
  if v_member_count=0 or v_seen_count*100<=v_member_count*55 then
    raise exception 'La sostituzione è disponibile solo quando più del 55%% dei partecipanti ha già visto il film.';
  end if;

  v_normalized := lower(regexp_replace(v_title,'\s+',' ','g'));
  if v_normalized=v_current_normalized then
    raise exception 'Scegli un titolo diverso dalla nomination attuale.';
  end if;
  begin
    update public.movie_nominations set title=v_title,normalized_title=v_normalized,
      omdb_id=nullif(trim(p_omdb_id),'') where id=p_nomination_id;
  exception when unique_violation then
    raise exception 'Questo titolo è già stato nominato nella serata.';
  end;

  select d.id into v_drawn_film_id
  from public.drawn_films d where d.nomination_id=p_nomination_id for update;
  if v_drawn_film_id is not null then
    delete from public.seen_votes where drawn_film_id=v_drawn_film_id;
    delete from public.movie_ratings where drawn_film_id=v_drawn_film_id;
    delete from public.drawn_film_metadata where drawn_film_id=v_drawn_film_id;
    update public.drawn_films set title=v_title,status='checking',vote_count=0,seen_count=0,
      rating_count=0,decided_at=null where id=v_drawn_film_id;
  end if;
end;
$$;

-- Prevent the organizer from drawing a queued nomination that is already
-- certain to fail, giving its owner time to replace it first.
create or replace function public.admin_draw_next(p_night_id uuid)
returns uuid language plpgsql security definer set search_path=''
as $$
declare
  v_phase text;
  v_nomination record;
  v_film_id uuid := gen_random_uuid();
  v_member_count integer;
  v_vote_count integer;
  v_seen_count integer;
  v_status text;
  v_decided_at timestamptz;
begin
  if auth.uid() is null or not public.is_current_user_admin() then
    raise exception 'Operazione riservata all’admin.';
  end if;
  select phase into v_phase from public.movie_nights where id=p_night_id for update;
  if v_phase is distinct from 'nominations' then raise exception 'La fase nomination è terminata.'; end if;
  if exists(select 1 from public.night_members where night_id=p_night_id and not has_nominated) then
    raise exception 'Attendi che tutti inviino una nomination.';
  end if;
  if exists(select 1 from public.movie_nominations n
    where n.night_id=p_night_id and n.status='queued'
      and (select count(*) filter(where nsv.has_seen)
        from public.nomination_seen_votes nsv
        join public.night_members nm on nm.night_id=p_night_id and nm.user_id=nsv.user_id
        where nsv.nomination_id=n.id)*100
        > (select count(*) from public.night_members where night_id=p_night_id)*55) then
    raise exception 'Chi ha proposto una nomination già vista deve sostituirla prima del sorteggio.';
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
  select count(*)::integer into v_member_count
  from public.night_members where night_id=p_night_id;
  select count(*)::integer,count(*) filter(where nsv.has_seen)::integer
    into v_vote_count,v_seen_count
  from public.nomination_seen_votes nsv where nsv.nomination_id=v_nomination.id;
  if v_vote_count=v_member_count then
    v_status := case when v_seen_count*100 > v_member_count*55 then 'rejected' else 'approved' end;
    v_decided_at := now();
  else
    v_status := 'checking';
    v_decided_at := null;
  end if;
  update public.movie_nominations set status='drawn' where id=v_nomination.id;
  insert into public.drawn_films(
    id,night_id,nomination_id,title,category_id,status,member_count,vote_count,seen_count,decided_at
  ) values (
    v_film_id,p_night_id,v_nomination.id,v_nomination.title,v_nomination.category_id,
    v_status,v_member_count,v_vote_count,v_seen_count,v_decided_at
  );
  insert into public.seen_votes(drawn_film_id,user_id,has_seen,voted_at)
  select v_film_id,nsv.user_id,nsv.has_seen,nsv.voted_at
  from public.nomination_seen_votes nsv where nsv.nomination_id=v_nomination.id
  on conflict(drawn_film_id,user_id) do update
    set has_seen=excluded.has_seen,voted_at=excluded.voted_at;
  return v_film_id;
end;
$$;

-- Preserve compatibility with already-open clients that still call the old RPC.
create or replace function public.replace_rejected_nomination(
  p_drawn_film_id uuid,p_title text,p_omdb_id text
)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_nomination_id uuid;
begin
  select d.nomination_id into v_nomination_id
  from public.drawn_films d where d.id=p_drawn_film_id;
  if v_nomination_id is null then raise exception 'Film o nomination non disponibili.'; end if;
  perform public.replace_nomination_after_seen_vote(v_nomination_id,p_title,p_omdb_id);
end;
$$;

revoke all on function public.replace_nomination_after_seen_vote(uuid,text,text) from public,anon,authenticated;
grant execute on function public.replace_nomination_after_seen_vote(uuid,text,text) to authenticated;
