-- Store one mutable seen/unseen vote per night member and nomination, including
-- nominations that have not been drawn yet.
create table if not exists public.nomination_seen_votes (
  nomination_id uuid not null references public.movie_nominations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  has_seen boolean not null,
  voted_at timestamptz not null default now(),
  primary key (nomination_id,user_id)
);

insert into public.nomination_seen_votes(nomination_id,user_id,has_seen,voted_at)
select d.nomination_id,sv.user_id,sv.has_seen,sv.voted_at
from public.seen_votes sv
join public.drawn_films d on d.id=sv.drawn_film_id
on conflict(nomination_id,user_id) do nothing;

alter table public.nomination_seen_votes enable row level security;
drop policy if exists own_nomination_seen_vote_read on public.nomination_seen_votes;
create policy own_nomination_seen_vote_read on public.nomination_seen_votes
  for select to authenticated using(user_id=auth.uid());
revoke all on public.nomination_seen_votes from public,anon,authenticated;
grant select on public.nomination_seen_votes to authenticated;

create or replace function public.get_night_nomination_list(p_night_id uuid)
returns table(
  id uuid,user_id uuid,title text,status text,vote_count integer,seen_count integer,
  member_count integer,my_has_seen boolean
)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_member_count integer;
begin
  if auth.uid() is null or not public.is_night_member(p_night_id) then
    raise exception 'Non fai parte di questa serata.';
  end if;
  select count(*)::integer into v_member_count
  from public.night_members nm where nm.night_id=p_night_id;
  return query
    select n.id,n.user_id,n.title,n.status,
      coalesce(v.vote_count,0)::integer,coalesce(v.seen_count,0)::integer,
      v_member_count,v.my_has_seen
    from public.movie_nominations n
    left join lateral (
      select count(*)::integer as vote_count,
        count(*) filter(where nsv.has_seen)::integer as seen_count,
        bool_or(nsv.has_seen) filter(where nsv.user_id=auth.uid()) as my_has_seen
      from public.nomination_seen_votes nsv
      where nsv.nomination_id=n.id
    ) v on true
    where n.night_id=p_night_id
    order by n.created_at,n.id;
end;
$$;

create or replace function public.submit_nomination_seen_vote(p_nomination_id uuid,p_has_seen boolean)
returns text language plpgsql security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_phase text;
  v_member_count integer;
  v_vote_count integer;
  v_seen_count integer;
  v_drawn_film_id uuid;
  v_drawn_status text;
  v_next_status text;
begin
  if auth.uid() is null then raise exception 'Accedi per votare.'; end if;
  if p_has_seen is null then raise exception 'Scegli se hai già visto il film.'; end if;
  select n.night_id into v_night_id
  from public.movie_nominations n where n.id=p_nomination_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;

  -- Use the night row as the shared lock, so voting cannot race against a draw,
  -- replacement, rating, or finalization for this game.
  select n.phase into v_phase
  from public.movie_nights n where n.id=v_night_id for update;
  if v_phase is distinct from 'nominations' then
    raise exception 'Il periodo per modificare il voto è terminato.';
  end if;
  perform 1 from public.movie_nominations n
  where n.id=p_nomination_id and n.night_id=v_night_id for update;
  if not found then raise exception 'Nomination non disponibile.'; end if;

  select count(*)::integer into v_member_count
  from public.night_members nm where nm.night_id=v_night_id;
  if v_member_count=0 then raise exception 'Nessun partecipante disponibile.'; end if;
  insert into public.nomination_seen_votes(nomination_id,user_id,has_seen)
  values(p_nomination_id,auth.uid(),p_has_seen)
  on conflict(nomination_id,user_id)
  do update set has_seen=excluded.has_seen,voted_at=now();
  select count(*)::integer,count(*) filter(where nsv.has_seen)::integer
    into v_vote_count,v_seen_count
  from public.nomination_seen_votes nsv where nsv.nomination_id=p_nomination_id;

  select d.id,d.status into v_drawn_film_id,v_drawn_status
  from public.drawn_films d where d.nomination_id=p_nomination_id for update;
  if v_drawn_film_id is null then return 'queued'; end if;

  insert into public.seen_votes(drawn_film_id,user_id,has_seen,voted_at)
  values(v_drawn_film_id,auth.uid(),p_has_seen,now())
  on conflict(drawn_film_id,user_id)
  do update set has_seen=excluded.has_seen,voted_at=excluded.voted_at;

  if v_vote_count=v_member_count then
    v_next_status := case when v_seen_count*100 > v_member_count*55 then 'rejected' else 'approved' end;
    if v_next_status='rejected' and v_drawn_status='approved' then
      delete from public.movie_ratings where drawn_film_id=v_drawn_film_id;
      update public.drawn_films set rating_count=0 where id=v_drawn_film_id;
    end if;
    update public.drawn_films set vote_count=v_vote_count,seen_count=v_seen_count,
      status=v_next_status,decided_at=now()
    where id=v_drawn_film_id;
    return v_next_status;
  end if;

  update public.drawn_films set vote_count=v_vote_count,seen_count=v_seen_count,
    status='checking',decided_at=null
  where id=v_drawn_film_id;
  return 'checking';
end;
$$;

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

-- Keep the existing Home buttons using the same vote store as the participant list.
create or replace function public.submit_seen_vote(p_drawn_film_id uuid,p_has_seen boolean)
returns text language plpgsql security definer set search_path=''
as $$
declare
  v_nomination_id uuid;
begin
  select d.nomination_id into v_nomination_id
  from public.drawn_films d where d.id=p_drawn_film_id;
  if v_nomination_id is null then raise exception 'Film o serata non disponibili.'; end if;
  return public.submit_nomination_seen_vote(v_nomination_id,p_has_seen);
end;
$$;

create or replace function public.get_my_seen_vote(p_drawn_film_id uuid)
returns boolean language sql stable security definer set search_path=''
as $$
  select nsv.has_seen
  from public.nomination_seen_votes nsv
  join public.drawn_films d on d.nomination_id=nsv.nomination_id
  where d.id=p_drawn_film_id and nsv.user_id=auth.uid()
    and public.is_night_member(d.night_id) limit 1;
$$;

-- Use a consistent night-then-film lock order for mutable ratings.
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
  select d.night_id into v_night_id from public.drawn_films d where d.id=p_drawn_film_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  select n.phase into v_phase from public.movie_nights n where n.id=v_night_id for update;
  if v_phase is distinct from 'nominations' then
    raise exception 'La classifica è già stata finalizzata.';
  end if;
  select d.status into v_status from public.drawn_films d
  where d.id=p_drawn_film_id and d.night_id=v_night_id for update;
  if v_status is distinct from 'approved' then raise exception 'Il film non è stato approvato.'; end if;

  insert into public.movie_ratings(drawn_film_id,user_id,rating)
  values(p_drawn_film_id,auth.uid(),p_rating)
  on conflict(drawn_film_id,user_id)
  do update set rating=excluded.rating,rated_at=now();
  update public.drawn_films set rating_count=(
    select count(*) from public.movie_ratings where drawn_film_id=p_drawn_film_id
  ) where id=p_drawn_film_id;
  if not exists(select 1 from public.movie_nominations where night_id=v_night_id and status='queued')
     and not exists(select 1 from public.drawn_films where night_id=v_night_id and status in ('checking','rejected'))
     and not exists(select 1 from public.drawn_films d where d.night_id=v_night_id and d.status='approved'
       and (select count(*) from public.movie_ratings r where r.drawn_film_id=d.id)<d.member_count) then
    update public.movie_nights set phase='leaderboard' where id=v_night_id and phase='nominations';
  end if;
end;
$$;

-- Keep replacement writes in the same night-first order as vote writes.
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
  select d.night_id,d.nomination_id into v_night_id,v_nomination_id
  from public.drawn_films d where d.id=p_drawn_film_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  select n.phase,n.revealed_count into v_phase,v_revealed_count
  from public.movie_nights n where n.id=v_night_id for update;
  if v_phase='complete' and v_revealed_count=0 then
    update public.movie_nights set phase='nominations',finished_at=null where id=v_night_id;
  elsif v_phase is distinct from 'nominations' then
    raise exception 'La fase nomination è terminata.';
  end if;
  select d.status into v_status from public.drawn_films d
  where d.id=p_drawn_film_id and d.night_id=v_night_id for update;
  if v_status is distinct from 'rejected' then
    raise exception 'La sostituzione è disponibile solo dopo un voto sfavorevole.';
  end if;
  select n.status into v_status from public.movie_nominations n
  where n.id=v_nomination_id and n.user_id=auth.uid() for update;
  if not found then raise exception 'Solo chi ha proposto il film può sostituirlo.'; end if;
  v_normalized := lower(regexp_replace(v_title,'\s+',' ','g'));
  begin
    update public.movie_nominations set title=v_title,normalized_title=v_normalized,
      omdb_id=nullif(trim(p_omdb_id),'') where id=v_nomination_id;
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

-- If an owner replaces a rejected title, old votes must not carry over to the new film.
create or replace function public.clear_nomination_seen_votes_on_title_change()
returns trigger language plpgsql security definer set search_path=''
as $$
begin
  if old.title is distinct from new.title then
    delete from public.nomination_seen_votes where nomination_id=new.id;
  end if;
  return new;
end;
$$;
drop trigger if exists clear_nomination_seen_votes_after_title_change on public.movie_nominations;
create trigger clear_nomination_seen_votes_after_title_change
after update of title on public.movie_nominations
for each row execute procedure public.clear_nomination_seen_votes_on_title_change();

revoke all on function public.get_night_nomination_list(uuid) from public,anon,authenticated;
revoke all on function public.submit_nomination_seen_vote(uuid,boolean) from public,anon,authenticated;
revoke all on function public.clear_nomination_seen_votes_on_title_change() from public,anon,authenticated;
grant execute on function public.get_night_nomination_list(uuid) to authenticated;
grant execute on function public.submit_nomination_seen_vote(uuid,boolean) to authenticated;
