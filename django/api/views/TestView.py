from rest_framework.response import Response
from rest_framework.views import APIView


class TestView(APIView):
    """
    GET /api/test/

    A protected endpoint. Requires a valid access_token cookie.
    The global DEFAULT_PERMISSION_CLASSES = [IsAuthenticated] handles
    enforcement — no extra config needed here.

    Returns info about the authenticated user so you can confirm the
    full login → access → refresh cycle works end-to-end.
    """

    def get(self, request):
        return Response({
            'message': 'Authenticated!',
            'user': {
                'id':       request.user.id,
                'username': request.user.username,
                'email':    request.user.email,
            },
        })
