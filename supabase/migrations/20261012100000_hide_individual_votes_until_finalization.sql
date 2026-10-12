-- Individual ballots are available to night members only after the organizer
-- has finalized and published the leaderboard.
create or replace function public.get_nomination_vote_details(p_nomination_id uuid)
returns table(
  username text,
  has_seen boolean,
  seen_voted_at timestamptz,
  rating numeric,
  rated_at timestamptz
)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_night_id uuid;
  v_phase text;
begin
  if auth.uid() is null then
    raise exception 'Accedi per visualizzare i voti.';
  end if;
  select n.night_id,mn.phase into v_night_id,v_phase
  from public.movie_nominations n
  join public.movie_nights mn on mn.id=n.night_id
  where n.id=p_nomination_id;
  if v_night_id is null or not public.is_night_member(v_night_id) then
    raise exception 'Film o serata non disponibili.';
  end if;
  if v_phase is distinct from 'complete' then
    raise exception 'I voti individuali saranno visibili dopo la pubblicazione della classifica.';
  end if;

  return query
    select p.username,nsv.has_seen,nsv.voted_at,mr.rating,mr.rated_at
    from public.night_members nm
    join public.profiles p on p.id=nm.user_id
    left join public.nomination_seen_votes nsv
      on nsv.nomination_id=p_nomination_id and nsv.user_id=nm.user_id
    left join public.drawn_films d on d.nomination_id=p_nomination_id
    left join public.movie_ratings mr
      on mr.drawn_film_id=d.id and mr.user_id=nm.user_id
    where nm.night_id=v_night_id
    order by lower(p.username),p.username;
end;
$$;

-- Do not send external scores to authenticated clients, even through direct
-- PostgREST table queries. The app retains access only to movie description data.
revoke select on public.drawn_film_metadata from authenticated;
revoke select (imdb_rating,imdb_votes,metascore) on public.drawn_film_metadata from authenticated;
grant select (
  drawn_film_id,found,imdb_id,title,year,rated,released,runtime,genre,director,
  actors,plot,language,country,awards,poster_url
) on public.drawn_film_metadata to authenticated;

revoke all on function public.get_nomination_vote_details(uuid) from public,anon,authenticated;
grant execute on function public.get_nomination_vote_details(uuid) to authenticated;
