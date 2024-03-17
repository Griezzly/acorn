// Code generated by protoc-gen-go-grpc. DO NOT EDIT.
// versions:
// - protoc-gen-go-grpc v1.2.0
// - protoc             v3.12.4
// source: request.proto

package grpc

import (
	context "context"
	grpc "google.golang.org/grpc"
	codes "google.golang.org/grpc/codes"
	status "google.golang.org/grpc/status"
)

// This is a compile-time assertion to ensure that this generated file
// is compatible with the grpc package it is being compiled against.
// Requires gRPC-Go v1.32.0 or later.
const _ = grpc.SupportPackageIsVersion7

// AcornClient is the client API for Acorn service.
//
// For semantics around ctx use and closing/ending streaming RPCs, please refer to https://pkg.go.dev/google.golang.org/grpc/?tab=doc#ClientConn.NewStream.
type AcornClient interface {
	Request(ctx context.Context, in *Request, opts ...grpc.CallOption) (*Response, error)
}

type acornClient struct {
	cc grpc.ClientConnInterface
}

func NewAcornClient(cc grpc.ClientConnInterface) AcornClient {
	return &acornClient{cc}
}

func (c *acornClient) Request(ctx context.Context, in *Request, opts ...grpc.CallOption) (*Response, error) {
	out := new(Response)
	err := c.cc.Invoke(ctx, "/proto.Acorn/request", in, out, opts...)
	if err != nil {
		return nil, err
	}
	return out, nil
}

// AcornServer is the server API for Acorn service.
// All implementations must embed UnimplementedAcornServer
// for forward compatibility
type AcornServer interface {
	Request(context.Context, *Request) (*Response, error)
	mustEmbedUnimplementedAcornServer()
}

// UnimplementedAcornServer must be embedded to have forward compatible implementations.
type UnimplementedAcornServer struct {
}

func (UnimplementedAcornServer) Request(context.Context, *Request) (*Response, error) {
	return nil, status.Errorf(codes.Unimplemented, "method Request not implemented")
}
func (UnimplementedAcornServer) mustEmbedUnimplementedAcornServer() {}

// UnsafeAcornServer may be embedded to opt out of forward compatibility for this service.
// Use of this interface is not recommended, as added methods to AcornServer will
// result in compilation errors.
type UnsafeAcornServer interface {
	mustEmbedUnimplementedAcornServer()
}

func RegisterAcornServer(s grpc.ServiceRegistrar, srv AcornServer) {
	s.RegisterService(&Acorn_ServiceDesc, srv)
}

func _Acorn_Request_Handler(srv interface{}, ctx context.Context, dec func(interface{}) error, interceptor grpc.UnaryServerInterceptor) (interface{}, error) {
	in := new(Request)
	if err := dec(in); err != nil {
		return nil, err
	}
	if interceptor == nil {
		return srv.(AcornServer).Request(ctx, in)
	}
	info := &grpc.UnaryServerInfo{
		Server:     srv,
		FullMethod: "/proto.Acorn/request",
	}
	handler := func(ctx context.Context, req interface{}) (interface{}, error) {
		return srv.(AcornServer).Request(ctx, req.(*Request))
	}
	return interceptor(ctx, in, info, handler)
}

// Acorn_ServiceDesc is the grpc.ServiceDesc for Acorn service.
// It's only intended for direct use with grpc.RegisterService,
// and not to be introspected or modified (even as a copy)
var Acorn_ServiceDesc = grpc.ServiceDesc{
	ServiceName: "proto.Acorn",
	HandlerType: (*AcornServer)(nil),
	Methods: []grpc.MethodDesc{
		{
			MethodName: "request",
			Handler:    _Acorn_Request_Handler,
		},
	},
	Streams:  []grpc.StreamDesc{},
	Metadata: "request.proto",
}
