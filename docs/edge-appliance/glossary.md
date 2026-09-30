# Edge Appliance glossary

This starter glossary defines Kubernetes and operator terms used when discussing
Edge Appliance work in UCK. It deliberately avoids product-specific behavior
that is not implemented or documented in this repository. Extend it as the
Edge Appliance API and its resources are defined.

## Adapter

The code that translates between a Custom Resource and an external API. In UCK,
each managed kind provides an adapter to the generic reconciler. See
Adding a kind.

## Adoption

Associating an existing external resource with a Custom Resource when the
resource's external identifier is not yet recorded in status. UCK adapters may
adopt resources using the Kubernetes object's UID label when the external API
supports labels.

## Condition

A structured status entry that records the current state of a Custom Resource,
such as whether it is ready or reconciliation has failed.

## Custom Resource

A Kubernetes object defined by a Custom Resource Definition. A Custom Resource
contains the desired configuration in `spec` and may expose observed state in
`status`.

## Custom Resource Definition

A Kubernetes API extension, commonly abbreviated as CRD, that defines a Custom
Resource's schema, group, version, and kind.

## Deletion policy

A setting that controls what happens to an external resource when its Custom
Resource is deleted. Supported policies and resource-specific behavior are
documented in the resource reference.

## External identifier

The stable value used to identify a resource in an external API, often a UUID or
name. UCK records external identifiers in a Custom Resource's status.

## Finalizer

Metadata on a Kubernetes object that delays its removal until the responsible
controller has completed required deletion handling.

## Observe

The adapter operation that reads an external resource and determines whether it
exists and matches the desired state. Observation must not change resources in
the external API.

## Reconciliation

The controller loop that compares desired state from a Custom Resource with
observed state and takes steps to bring them together.

## Secret

A Kubernetes object used for sensitive data. Credentials and connection details
produced by UCK are written to Secrets owned by the relevant Custom Resource,
not to status.

## Status

The part of a Custom Resource that reports observed state, including external
identifiers and conditions. Status is not the source of desired configuration.
