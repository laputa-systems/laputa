##! Observed state as typed values. A fact is what a host reported; an
##! unreadable fact is its own case and is never taken for absence.

## Why a fact could not be read.
export enum Cause: Str { Denied = "denied", Unavailable = "unavailable", Malformed = "malformed", Conflict = "conflict" }

## A fact that could not be established, with the reason and the detail the
## host gave.
export type Unreadable = {cause: Cause, detail: Str}

## The kind of filesystem object at a path, never following a final symlink.
export enum PathKind: Str { Directory = "dir", Regular = "file", Symlink = "link", Other = "other" }

## What `stat` and the content probe reported for an existing path.
export type PathInfo = {
  kind: PathKind,
  mode: Int,
  uid: Int,
  gid: Int,
  owner: Str,
  group: Str,
  size: Int,
  digest: Str?,
  link_target: Str?,
}

## The state of one path.
export enum PathState { Missing, Found(PathInfo), Blocked(Unreadable), Unseen(Unreadable) }

## How the installed version compares with the wanted version in apk ordering.
export enum Ordering: Str { Older = "lt", Same = "eq", Newer = "gt" }

## An installed package version and, when a bound was asked for, how it orders
## against the bound.
export type InstalledPackage = {version: Str, ordering: Ordering?}

## The state of one package in the apk database.
export enum PackageState { NotInstalled, Installed(InstalledPackage), PackageUnseen(Unreadable) }

## One group of the account database.
export type GroupInfo = {name: Str, gid: Int, members: List[Str]}

## One user of the account database, with the groups it belongs to.
export type UserInfo = {
  name: Str,
  uid: Int,
  gid: Int,
  group: Str?,
  home: Str,
  shell: Str,
  memberships: List[Str],
}

## The state of one group.
export enum GroupState { NoGroup, GroupFound(GroupInfo), GroupUnseen(Unreadable) }

## The state of one user.
export enum UserState { NoUser, UserFound(UserInfo), UserUnseen(Unreadable) }

## Whether an init script reports its service started, stopped, or otherwise.
export enum Running: Str { Started = "started", Stopped = "stopped", Crashed = "crashed", Indeterminate = "indeterminate" }

## What the service manager reported for one service. `enabled` is null when
## the manager has no enablement notion; `ready` is null when it reports none.
export type ServiceInfo = {enabled: Bool?, running: Running, ready: Bool?}

## The state of one service.
export enum ServiceState { NoService, ServiceFound(ServiceInfo), ServiceUnseen(Unreadable) }

## The exit status of a read-only guard command.
export enum GuardState { Exited(Int), GuardUnseen(Unreadable) }

## An observation of whichever kind a resource needs.
export enum Fact {
  OnPath(PathState),
  OnPackage(PackageState),
  OnGroup(GroupState),
  OnUser(UserState),
  OnService(ServiceState),
  OnGuard(GuardState),
  Nothing,
}

