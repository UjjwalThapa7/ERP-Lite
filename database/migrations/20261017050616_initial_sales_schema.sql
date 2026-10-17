create table public.shop_members (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.shop_members enable row level security;

create or replace function public.is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.shop_members where user_id = auth.uid());
$$;

create or replace function public.claim_shop() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if exists (select 1 from public.shop_members where user_id = auth.uid()) then return true; end if;
  if exists (select 1 from public.shop_members) then return false; end if;
  insert into public.shop_members(user_id) values (auth.uid());
  return true;
end $$;

create table public.sales (
  id uuid primary key,
  sold_at timestamptz not null,
  subtotal numeric(12,2) not null check (subtotal >= 0),
  discount numeric(12,2) not null default 0 check (discount >= 0),
  total numeric(12,2) not null check (total >= 0),
  method text not null check (method in ('Cash','Fonepay','Split')),
  cash numeric(12,2) not null default 0 check (cash >= 0),
  fonepay numeric(12,2) not null default 0 check (fonepay >= 0),
  note text,
  status text not null default 'ok' check (status in ('ok','void')),
  void_reason text,
  voided_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (cash + fonepay = total)
);
create index sales_sold_at_idx on public.sales (sold_at desc);

create table public.sale_items (
  id bigint generated always as identity primary key,
  sale_id uuid not null references public.sales(id) on delete restrict,
  name text not null,
  price numeric(12,2) not null check (price > 0),
  qty integer not null check (qty > 0)
);
create index sale_items_sale_idx on public.sale_items (sale_id);

create table public.sale_events (
  id bigint generated always as identity primary key,
  sale_id uuid not null references public.sales(id) on delete restrict,
  at timestamptz not null default now(),
  what text not null,
  reason text,
  by_user uuid default auth.uid()
);

alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.sale_events enable row level security;

create policy members_read_sales on public.sales for select to authenticated using (public.is_member());
create policy members_read_items on public.sale_items for select to authenticated using (public.is_member());
create policy members_read_events on public.sale_events for select to authenticated using (public.is_member());
create policy members_self on public.shop_members for select to authenticated using (user_id = auth.uid());
-- no insert/update/delete policies: all writes go through the functions below

create or replace function public.save_sale(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare sid uuid := (p->>'id')::uuid; it jsonb;
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  if exists (select 1 from public.sales where id = sid) then return sid; end if; -- idempotent: same id never saved twice
  insert into public.sales(id, sold_at, subtotal, discount, total, method, cash, fonepay, note)
  values (sid, (p->>'sold_at')::timestamptz, (p->>'subtotal')::numeric, (p->>'discount')::numeric,
          (p->>'total')::numeric, p->>'method', (p->>'cash')::numeric, (p->>'fonepay')::numeric, nullif(p->>'note',''));
  for it in select * from jsonb_array_elements(p->'items') loop
    insert into public.sale_items(sale_id, name, price, qty)
    values (sid, it->>'name', (it->>'price')::numeric, (it->>'qty')::int);
  end loop;
  insert into public.sale_events(sale_id, what) values (sid, 'created');
  return sid;
end $$;

create or replace function public.void_sale(sid uuid, reason text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member() then raise exception 'not allowed'; end if;
  update public.sales set status='void', void_reason=nullif(reason,''), voided_at=now() where id=sid and status='ok';
  if found then insert into public.sale_events(sale_id, what, reason) values (sid,'voided',nullif(reason,'')); end if;
end $$;

revoke all on function public.save_sale(jsonb), public.void_sale(uuid,text), public.claim_shop() from public, anon;
grant execute on function public.save_sale(jsonb), public.void_sale(uuid,text), public.claim_shop() to authenticated;
revoke all on function public.is_member() from public, anon;
grant execute on function public.is_member() to authenticated;
